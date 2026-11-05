# Fixture for Punch/MailDelivery: mail sent around Punch::Mailer.
class Welcome < Carbon::Email # expect
end

Carbon::DevAdapter.new    # expect
Carbon::SmtpAdapter.new   # expect
Welcome.new.deliver_later # expect
Punch::Mailer.adapter { Punch::Mailer::CarbonAdapter.new(Carbon::SendGridAdapter.new(api_key: "k")) }
Punch::Mailer.deliver(mail, locale: locale, job: job)
