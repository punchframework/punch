struct Billing::Address
  # The address as it is written on an envelope, one line each.
  def lines : Array(String)
    [street.value, "#{postal_code} #{city}", country.value]
  end
end
