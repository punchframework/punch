-- Mixed load for the reference app: 80% reads, 20% writes.
-- Reads: an invoice with its lines (60%), the first page of 20 invoices
-- (20%; later pages need the cursor the previous page returns).
-- Writes: a new draft with two lines (10%), a revision of a draft (10%).
-- run.sh seeds 50 customers and 1,000 drafts first, and passes an API
-- token in TOKEN.
math.randomseed(os.time())
local auth = "Bearer " .. os.getenv("TOKEN")
local read = {["Authorization"] = auth}
local write = {["Authorization"] = auth, ["Content-Type"] = "application/json"}
local lines = '[{"description":"Consulting","quantity":3,"unit_price":12500},{"description":"Travel","quantity":1,"unit_price":4990}]'

request = function()
  local roll = math.random(100)
  local invoice = math.random(1000)
  if roll <= 60 then
    return wrk.format("GET", "/billing/invoices/" .. invoice, read)
  elseif roll <= 80 then
    return wrk.format("GET", "/billing/invoices?limit=20", read)
  elseif roll <= 90 then
    local body = '{"customer_id":' .. math.random(50) .. ',"currency":"EUR","lines":' .. lines .. '}'
    return wrk.format("POST", "/billing/invoices", write, body)
  else
    return wrk.format("PATCH", "/billing/invoices/" .. invoice, write, '{"currency":"CHF","lines":' .. lines .. '}')
  end
end

-- Counts responses that are not 2xx by status, printed at the end.
local threads = {}

function setup(thread)
  table.insert(threads, thread)
end

function init(args)
  failures = {}
end

function response(status, headers, body)
  if status >= 300 then
    failures[status] = (failures[status] or 0) + 1
  end
end

function done(summary, latency, requests)
  for _, thread in ipairs(threads) do
    for status, count in pairs(thread:get("failures")) do
      io.write(string.format("status %d: %d\n", status, count))
    end
  end
end
