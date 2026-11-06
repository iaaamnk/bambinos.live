$invoices = Import-Csv '1_invoices.csv'
$forms = Import-Csv '2_faculty_form_unapproved.csv'
$ref = Import-Csv 'reference_active_batches_and_students.csv'

$refMap = @{}
foreach ($r in $ref) {
    $refMap[$r.student_id] = $r
}

$approved = [System.Collections.Generic.List[PSObject]]::new()
$exceptions = [System.Collections.Generic.List[PSObject]]::new()
$messages = [System.Collections.Generic.List[PSObject]]::new()

$matchedFormIds = [System.Collections.Generic.HashSet[string]]::new()

# Helper for adding messages
function Add-Msg ($type, $name, $contact, $channel, $template, $text) {
    $messages.Add([PSCustomObject]@{
        recipient_type    = $type
        recipient_name    = $name
        recipient_contact = $contact
        channel           = $channel
        template_id       = $template
        message_text      = $text
    })
}

# Helper for adding exceptions
function Add-Exc ($invId, $stuId, $formId, $code, $sev, $owner, $details, $action) {
    $exceptions.Add([PSCustomObject]@{
        invoice_id         = $invId
        student_id         = $stuId
        faculty_form_id    = $formId
        reason_code        = $code
        severity           = $sev
        owner              = $owner
        details            = $details
        recommended_action = $action
        flagged_timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    })
}

foreach ($inv in $invoices) {
    $invId = $inv.id
    $stuId = $inv.student_id
    $payStatus = $inv.payment_status
    $netAmt = [double]$inv.net_amount
    $grossAmt = [double]$inv.amount
    $discAmt = [double]$inv.discount_amount
    $rStu = $refMap[$stuId]

    # Step 1: Payment Check
    if ($payStatus -ne 'Paid') {
        $candForms = $forms | Where-Object { $_.invoice_id -eq $invId -or $_.student_id -eq $stuId }
        $formId = if ($candForms) { $candForms[0].id } else { 'NONE' }
        if ($candForms) { [void]$matchedFormIds.Add($candForms[0].id) }

        Add-Exc $invId $stuId $formId "PAYMENT_NOT_CONFIRMED" "CRITICAL" "Parent / Gateway Ops" "Payment status is '$payStatus'. Gateway payment ID is null or unconfirmed." "Do not schedule. Send instant retry link via WhatsApp."
        Add-Msg "Parent" $inv.parent_name $inv.mobile "WhatsApp" "PAYMENT_FAILED_RETRY" "Dear $($inv.parent_name), your renewal payment of INR $grossAmt for $(if ($rStu) { $rStu.student_name_masked } else { 'your child' }) failed at gateway. Please retry securely here: $($inv.invoice_link)"
        continue
    }

    # Step 2: Form Matching (Exact first, then Fallback on Student ID)
    $candForms = @($forms | Where-Object { $_.invoice_id -eq $invId })
    $matchType = "EXACT_INVOICE_ID"
    $mForm = $null

    if ($candForms.Count -gt 0) {
        $mForm = $candForms[0]
        # Check duplicate forms
        if ($candForms.Count -gt 1) {
            for ($i = 1; $i -lt $candForms.Count; $i++) {
                [void]$matchedFormIds.Add($candForms[$i].id)
                Add-Exc $invId $stuId $candForms[$i].id "DUPLICATE_FORM_SUBMISSION" "LOW" "Ops / Engine Auto-Dedupe" "Duplicate submission detected. Remarks: '$($candForms[$i].remarks)'." "Discard duplicate; process primary submission."
            }
        }
    } else {
        # Fallback by student_id
        $candByStu = @($forms | Where-Object { $_.student_id -eq $stuId -and -not $matchedFormIds.Contains($_.id) })
        if ($candByStu.Count -gt 0) {
            $mForm = $candByStu[0]
            $matchType = "FALLBACK_STUDENT_ID_HEALED"
        }
    }

    # Step 3: Check Orphaned Invoice
    if (-not $mForm) {
        Add-Exc $invId $stuId "NONE" "ORPHANED_INVOICE_NO_FORM" "HIGH" "Educator / Ops Lead" "Payment received (INR $netAmt) but educator form was never submitted." "Notify educator to confirm attendance and submit renewal preferences."
        $edName = if ($rStu) { $rStu.educator_name } else { "Teacher" }
        Add-Msg "Educator" $edName "Educator_ID_$($inv.educator_id)" "Educator Portal" "ORPHANED_INVOICE_REMINDER" "Hi $edName, student ID $stuId completed renewal payment (Invoice $invId). Please confirm batch status."
        continue
    }

    [void]$matchedFormIds.Add($mForm.id)
    $formId = $mForm.id

    # If typo was healed, record non-blocking warning exception or note
    if ($matchType -eq "FALLBACK_STUDENT_ID_HEALED") {
        Add-Exc $invId $stuId $formId "INVOICE_ID_TYPO_HEALED" "MEDIUM" "Ops Verification" "Educator typed typo invoice '$($mForm.invoice_id)'. Healed via student_id $stuId." "Auto-correct invoice FK and route to 1-click Ops sign-off."
        # If conservative, don't auto-schedule without human 1-click confirmation:
        continue
    }

    # Step 4: Validate against Reference
    if (-not $rStu) {
        Add-Exc $invId $stuId $formId "STUDENT_NOT_IN_MASTER" "HIGH" "Ops Lead" "Student ID $stuId not found in master reference." "Escalate to Ops Lead to locate student profile."
        continue
    }

    # Step 5: Validate Price & Installments
    $stdFee = [double]$rStu.standard_fee_24_sessions_inr
    $formAmt = [double]$mForm.amount_paid
    $payType = $inv.payment_type

    if ($payType -like "Installment*" -or $netAmt -lt $stdFee) {
        if ($payType -like "Installment*") {
            Add-Exc $invId $stuId $formId "PARTIAL_INSTALLMENT_PAYMENT" "HIGH" "Finance / Ops" "Installment payment ($payType). Paid INR $netAmt vs Standard INR $stdFee. Form claimed 24 sessions." "Cap initial booking at 12 sessions or seek parent payment."
            continue
        } elseif ($discAmt -gt 0 -or $netAmt -ne $stdFee) {
            Add-Exc $invId $stuId $formId "UNAUTHORIZED_DISCOUNT_MISMATCH" "MEDIUM" "Finance Lead" "Net paid INR $netAmt differs from standard INR $stdFee (Discount INR $discAmt). Remarks: '$($mForm.remarks)'." "Review 20% scholarship authorization before booking."
            continue
        }
    }

    # Step 6: Validate Contact Phone
    $invPhone = ($inv.mobile -replace '[^\d]', '')
    $refPhone = ($rStu.registered_mobile_masked -replace '[^\d]', '')
    if ($invPhone.Length -ge 4 -and $refPhone.Length -ge 4) {
        $invEnd = $invPhone.Substring($invPhone.Length - 4)
        $refEnd = $refPhone.Substring($refPhone.Length - 4)
        if ($invEnd -ne $refEnd) {
            Add-Exc $invId $stuId $formId "PAYER_CONTACT_MISMATCH" "MEDIUM" "Ops Verification" "Invoice mobile (...$invEnd) differs from registered (...$refEnd). Remarks: '$($mForm.remarks)'." "Verify secondary guardian contact in CRM."
            continue
        }
    }

    # Step 7: Batch Continuity & Capacity
    $contSame = ($mForm.continue_same_batch.Trim().ToLower() -eq 'yes')
    $activeCount = [int]$rStu.active_students_count
    $maxSize = [int]$rStu.max_batch_size

    if (-not $contSame) {
        Add-Exc $invId $stuId $formId "BATCH_CHANGE_REQUESTED" "MEDIUM" "Parent Scheduling Ops" "Parent requested new batch: $($mForm.preferred_days) at $($mForm.preferred_time_slot). Current batch: $($rStu.current_classbatch_id)." "Send interactive batch-slot selection link to parent."
        Add-Msg "Parent" $inv.parent_name $inv.mobile "WhatsApp" "BATCH_CHANGE_SLOT_SELECTION" "Hello $($inv.parent_name), please choose your preferred slot for $($rStu.student_name_masked) from open batches: https://bambinos.live/select-batch?id=$stuId"
        continue
    }

    if ($activeCount -ge $maxSize) {
        Add-Exc $invId $stuId $formId "BATCH_OVERCAPACITY" "HIGH" "Batch Planning Ops" "Current batch $($rStu.current_classbatch_id) ($($rStu.classbatch_name)) is FULL ($activeCount/$maxSize)." "Offer parallel batch with same educator or split batch."
        Add-Msg "Parent" $inv.parent_name $inv.mobile "WhatsApp" "BATCH_FULL_PARALLEL_OPTION" "Dear $($inv.parent_name), $($rStu.student_name_masked)'s batch is at capacity. We held a seat in a parallel batch with $($rStu.educator_name). Confirm here: https://bambinos.live/confirm-slot?batch=parallel"
        continue
    }

    # Step 8: AUTO-APPROVE (Fast Lane)
    $approved.Add([PSCustomObject]@{
        invoice_id          = $invId
        student_id          = $stuId
        faculty_form_id     = $formId
        student_name        = $rStu.student_name_masked
        parent_name         = $inv.parent_name
        parent_mobile       = $inv.mobile
        classbatch_id       = $rStu.current_classbatch_id
        classbatch_name     = $rStu.classbatch_name
        class_id            = $rStu.class_id
        educator_id         = $rStu.educator_id
        educator_name       = $rStu.educator_name
        sessions_allocated  = 24
        amount_verified     = $netAmt
        batch_days          = $rStu.batch_days
        batch_start_time    = $rStu.batch_start_time
        approval_route      = "FAST_LANE_AUTO_APPROVED"
        approval_timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    })

    Add-Msg "Parent" $inv.parent_name $inv.mobile "WhatsApp" "INSTANT_SCHEDULE_CONFIRMED" "Renewal Confirmed! Dear $($inv.parent_name), $($rStu.student_name_masked)'s 24 renewal sessions in $($rStu.class_name) ($($rStu.classbatch_name)) with $($rStu.educator_name) are scheduled. Days: $($rStu.batch_days) at $($rStu.batch_start_time). View schedule: https://bambinos.live/my-classes"
}

# Check orphaned forms
foreach ($f in $forms) {
    if (-not $matchedFormIds.Contains($f.id)) {
        Add-Exc $f.invoice_id $f.student_id $f.id "PHANTOM_FORM_NO_INVOICE" "HIGH" "Finance Audit" "Form submitted with link '$($f.invoice_link)', but no invoice matches." "Audit submission with teacher."
    }
}

$approved | Export-Csv -Path 'approved.csv' -NoTypeInformation
$exceptions | Export-Csv -Path 'exceptions.csv' -NoTypeInformation
$messages | Export-Csv -Path 'messages.csv' -NoTypeInformation

Write-Host "Exported $($approved.Count) approved, $($exceptions.Count) exceptions, $($messages.Count) messages."
