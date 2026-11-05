module Billing::Logos
  # A logo: at most 2 MB, as a PNG or WebP.
  @[Punch::Upload::Rules(max_size: 2_000_000, types: ["image/png", "image/webp"])]
  struct Picture
    include Punch::Upload::Kind
  end
end
