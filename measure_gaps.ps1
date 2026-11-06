$invoices = Import-Csv '1_invoices.csv'
$forms = Import-Csv '2_faculty_form_unapproved.csv'
$bookings = Import-Csv '3_booking_requests.csv'
$schedules = Import-Csv '4_class_schedule_bookings.csv'

# Helper to calculate median and p90
function Get-Stats ($list) {
    if ($list.Count -eq 0) { return "N/A" }
    $sorted = $list | Sort-Object
    $count = $sorted.Count
    $mid = [math]::Floor($count / 2)
    if ($count % 2 -eq 0) {
        $median = ($sorted[$mid - 1] + $sorted[$mid]) / 2.0
    } else {
        $median = $sorted[$mid]
    }
    # 90th percentile (nearest rank or linear)
    $p90Idx = [math]::Ceiling(0.90 * $count) - 1
    if ($p90Idx -lt 0) { $p90Idx = 0 }
    $p90 = $sorted[$p90Idx]
    return @{ Median = [math]::Round($median, 1); P90 = [math]::Round($p90, 1); Count = $count; Values = $sorted }
}

# 1. Invoice Paid -> Form Created
$gaps_inv_to_form = @()
$weekday_inv_to_form = @()
$weekend_inv_to_form = @()

foreach ($f in $forms) {
    $invId = $f.invoice_id
    # Match on invoice
    $inv = $invoices | Where-Object { $_.id -eq $invId }
    if (-not $inv -and $f.student_id) {
        # Fallback for typo 84931 -> 84913
        $inv = $invoices | Where-Object { $_.student_id -eq $f.student_id }
    }
    if ($inv -and $inv.paid_at -ne 'NULL') {
        $t1 = [DateTime]::Parse($inv.paid_at)
        $t2 = [DateTime]::Parse($f.created_at)
        $diffMin = ($t2 - $t1).TotalMinutes
        $gaps_inv_to_form += $diffMin
        if ($t1.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)) {
            $weekend_inv_to_form += $diffMin
        } else {
            $weekday_inv_to_form += $diffMin
        }
        Write-Host "Form $($f.id) (Inv $($inv.id)): Day=$($t1.DayOfWeek), Diff=$diffMin min ($([math]::Round($diffMin/60, 2)) hrs)"
    }
}

Write-Host "`n--- Time Gap: Invoice Paid -> Form Created (minutes) ---"
$overall_stats = Get-Stats $gaps_inv_to_form
Write-Host "Overall: Median=$($overall_stats.Median)m, P90=$($overall_stats.P90)m (Count=$($overall_stats.Count))"
$wkday_stats = Get-Stats $weekday_inv_to_form
Write-Host "Weekday: Median=$($wkday_stats.Median)m, P90=$($wkday_stats.P90)m (Count=$($wkday_stats.Count))"
$wkend_stats = Get-Stats $weekend_inv_to_form
Write-Host "Weekend: Median=$($wkend_stats.Median)m, P90=$($wkend_stats.P90)m (Count=$($wkend_stats.Count))"

# 2. Form Created -> Approved
$gaps_form_to_appr = @()
$weekday_form_to_appr = @()
$weekend_form_to_appr = @()

foreach ($f in $forms) {
    if ($f.approved_at -ne 'NULL' -and -not [string]::IsNullOrWhiteSpace($f.approved_at)) {
        $t1 = [DateTime]::Parse($f.created_at)
        $t2 = [DateTime]::Parse($f.approved_at)
        $diffMin = ($t2 - $t1).TotalMinutes
        $gaps_form_to_appr += $diffMin
        if ($t1.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)) {
            $weekend_form_to_appr += $diffMin
        } else {
            $weekday_form_to_appr += $diffMin
        }
        Write-Host "Approved Form $($f.id): Day=$($t1.DayOfWeek), Diff=$diffMin min ($([math]::Round($diffMin/60, 2)) hrs)"
    }
}

Write-Host "`n--- Time Gap: Form Created -> Approved (minutes) ---"
$overall_appr = Get-Stats $gaps_form_to_appr
Write-Host "Overall: Median=$($overall_appr.Median)m, P90=$($overall_appr.P90)m (Count=$($overall_appr.Count))"
$wkday_appr = Get-Stats $weekday_form_to_appr
Write-Host "Weekday: Median=$($wkday_appr.Median)m, P90=$($wkday_appr.P90)m (Count=$($wkday_appr.Count))"
$wkend_appr = Get-Stats $weekend_form_to_appr
Write-Host "Weekend: Median=$($wkend_appr.Median)m, P90=$($wkend_appr.P90)m (Count=$($wkend_appr.Count))"

# 3. Form Approved -> Booking Allocated
$gaps_appr_to_alloc = @()
foreach ($b in $bookings) {
    if ($b.allocated_at -ne 'NULL' -and -not [string]::IsNullOrWhiteSpace($b.allocated_at)) {
        $f = $forms | Where-Object { $_.id -eq $b.faculty_form_id }
        $t1 = [DateTime]::Parse($f.approved_at)
        $t2 = [DateTime]::Parse($b.allocated_at)
        $diffMin = ($t2 - $t1).TotalMinutes
        $gaps_appr_to_alloc += $diffMin
        Write-Host "Allocated Booking $($b.id): Diff=$diffMin min"
    }
}
Write-Host "`n--- Time Gap: Form Approved -> Booking Allocated (minutes) ---"
$alloc_stats = Get-Stats $gaps_appr_to_alloc
Write-Host "Overall: Median=$($alloc_stats.Median)m, P90=$($alloc_stats.P90)m (Count=$($alloc_stats.Count))"

# 4. Total End-to-End for the 1 scheduled booking
$sched = $schedules[0]
$inv1 = $invoices | Where-Object { $_.id -eq $sched.invoice_id }
$t_start = [DateTime]::Parse($inv1.paid_at)
$t_end = [DateTime]::Parse($sched.created_at)
Write-Host "`nTotal E2E time for scheduled invoice $($inv1.id): $(($t_end - $t_start).TotalMinutes) minutes ($([math]::Round((($t_end - $t_start).TotalMinutes)/60, 2)) hrs)"
