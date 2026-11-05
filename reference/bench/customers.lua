-- Load on customers for bench/convert-email.sh: lists (40%), one customer
-- (30%), a new customer (20%), a changed email (10%). Every email it
-- writes is new, so every response should be 2xx. PREFIX tells apart the
-- wrk runs that load two releases at once.
local auth = "Bearer " .. os.getenv("TOKEN")
local prefix = os.getenv("PREFIX") or "load"
local read = {["Authorization"] = auth}
local write = {["Authorization"] = auth, ["Content-Type"] = "application/json"}
local counter = 0

local function email()
  counter = counter + 1
  return prefix .. "-" .. thread_id .. "-" .. counter .. "@example.org"
end

request = function()
  local roll = math.random(100)
  local customer = math.random(50)
  if roll <= 40 then
    return wrk.format("GET", "/billing/customers?limit=20", read)
  elseif roll <= 70 then
    return wrk.format("GET", "/billing/customers/" .. customer, read)
  elseif roll <= 90 then
    return wrk.format("POST", "/billing/customers", write, '{"name":"Load","email":"' .. email() .. '"}')
  else
    return wrk.format("PATCH", "/billing/customers/" .. customer, write, '{"email":"' .. email() .. '"}')
  end
end

-- Counts responses that are not 2xx by status, printed at the end.
local threads = {}

function setup(thread)
  table.insert(threads, thread)
  thread:set("thread_id", #threads)
end

-- Each thread its own seed and emails: wrk's threads would otherwise
-- write the same addresses, which the unique index refuses.
function init(args)
  failures = {}
  math.randomseed(os.time() * 100 + thread_id)
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
