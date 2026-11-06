# ⚙️ Operations Track Assets — Student Renewal → Class Scheduling Pipeline

> **⚠️ Important:** Refer to and use the assets in this folder **ONLY** if you have been shortlisted for the **Operations Problem Statement (PS)**. Please read the Operations Problem Statement PDF shared with you in your shortlist email along with the root [`../README.md`](../README.md).

---

## 📂 Masked Production Tables in `./data/`

All 5 CSV files in [`./data/`](./data/) follow our **Bambinos.live MySQL production schema conventions** (`id`, `user_id`, `student_id`, `educator_id`, `class_id`, `classbatch_id`, `classschedule_id`, `'Yes'/'No'` enum flags, and `created_at` / `updated_at` / `deleted_at` soft-delete timestamps), with parent/student PII masked (`Pr***a Sh***a`, `+91-9811XXXX01`):

### 1. [`1_invoices.csv`](./data/1_invoices.csv) (`invoices` table)
Created when a parent pays via Razorpay/Stripe renewal link:
- **Columns:** `id`, `invoice_number`, `user_id`, `student_id`, `class_id`, `educator_id`, `parent_name`, `mobile`, `email`, `currency`, `amount`, `discount_amount`, `net_amount`, `payment_type`, `payment_mode`, `payment_gateway`, `gateway_order_id`, `gateway_payment_id`, `invoice_link`, `payment_status`, `is_renewal`, `paid_at`, `created_at`, `updated_at`, `deleted_at`

### 2. [`2_faculty_form_unapproved.csv`](./data/2_faculty_form_unapproved.csv) (`faculty_form_unapproved` table)
Created when the educator (teacher) manually submits a renewal form with the invoice link and payment details:
- **Columns:** `id`, `educator_id`, `educator_name`, `user_id`, `student_id`, `student_name`, `parent_mobile`, `class_id`, `current_classbatch_id`, `invoice_id`, `invoice_link`, `amount_paid`, `sessions_purchased`, `continue_same_batch`, `preferred_days`, `preferred_time_slot`, `remarks`, `approval_status`, `approved_by`, `approved_at`, `created_at`, `updated_at`, `deleted_at`

### 3. [`3_booking_requests.csv`](./data/3_booking_requests.csv) (`booking_requests` table)
Created after the Ops team manually approves a row from `faculty_form_unapproved`:
- **Columns:** `id`, `faculty_form_id`, `invoice_id`, `user_id`, `student_id`, `class_id`, `educator_id`, `classbatch_id`, `sessions_count`, `is_renewal`, `continue_same_batch`, `preferred_days`, `preferred_time`, `request_status`, `batch_allocated`, `allocated_by`, `allocated_at`, `created_at`, `updated_at`, `deleted_at`

### 4. [`4_class_schedule_bookings.csv`](./data/4_class_schedule_bookings.csv) (`classschedulebookings` table)
Created once the parent/Ops team selects the batch to continue with, scheduling actual live class sessions:
- **Columns:** `id`, `bookingrequest_id`, `invoice_id`, `classschedule_id`, `classbatch_id`, `class_id`, `user_id`, `student_id`, `educator_id`, `class_date`, `start_time`, `end_time`, `booking_type`, `is_cancelled`, `attended_class`, `created_at`, `updated_at`, `deleted_at`

### 5. [`reference_active_batches_and_students.csv`](./data/reference_active_batches_and_students.csv) (`classbatches` → `classes` → `categories` join)
Master lookup table mapping active students to their current batch, educator, standard course fee, and current batch capacity (`active_students_count` vs `max_batch_size`):
- **Columns:** `student_id`, `user_id`, `student_name_masked`, `parent_name_masked`, `registered_mobile_masked`, `registered_email_masked`, `current_classbatch_id`, `classbatch_name`, `class_id`, `class_name`, `category_id`, `category_name`, `educator_id`, `educator_name`, `standard_fee_24_sessions_inr`, `batch_days`, `batch_start_time`, `active_students_count`, `max_batch_size`, `deleted_at`
