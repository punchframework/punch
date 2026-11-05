# Punch/NamespaceFile: types outside the directory's namespace.
module Shop::Carts::Store
end

struct Shop::Orders::Total # expect
end

module Shop
  module Carts
    struct Line
    end
  end

  struct Other # expect
  end
end
