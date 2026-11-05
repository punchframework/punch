-- The sent invoices in ID order with their due date, for the daily
-- sweep of overdue invoices (Billing::Invoices::RemindOverdue).
CREATE INDEX invoices_sent_by_id ON invoices (id, due_at) WHERE status = 'sent';
