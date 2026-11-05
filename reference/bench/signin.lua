-- Sign-ins with a correct password from many accounts and addresses
-- (bench/signins.sh): each request takes the next account of ACCOUNTS and
-- a client address of its own in X-Forwarded-For, so neither the limit by
-- address nor the one by account refuses it first. Each connection waits
-- PAUSE_MS between requests: people sign in at a rate, they do not retry a
-- refusal at once, and a closed loop would repeat each account until its
-- limit refuses it. Counts answers by status.
local accounts = tonumber(os.getenv("ACCOUNTS"))
local password = os.getenv("PASSWORD")
local threads = {}
local next_id = 0

function setup(thread)
  thread:set("id", next_id)
  next_id = next_id + 1
  table.insert(threads, thread)
end

function init(args)
  counter = 0
  statuses = {}
end

request = function()
  counter = counter + 1
  local n = id * 1000000 + counter
  local account = n % accounts + 3
  local ip = "10." .. math.floor(n / 65536) % 256 .. "." .. math.floor(n / 256) % 256 .. "." .. n % 256
  local body = '{"email":"u' .. account .. '@example.org","password":"' .. password .. '"}'
  return wrk.format("POST", "/accounts/sessions", {["Content-Type"] = "application/json", ["X-Forwarded-For"] = ip}, body)
end

local pause = tonumber(os.getenv("PAUSE_MS") or "1000")

function delay()
  return pause
end

function response(status, headers, body)
  statuses[status] = (statuses[status] or 0) + 1
end

function done(summary, latency, requests)
  local total = {}
  for _, thread in ipairs(threads) do
    for status, count in pairs(thread:get("statuses")) do
      total[status] = (total[status] or 0) + count
    end
  end
  for status, count in pairs(total) do
    io.write(string.format("sign-in status %d: %d\n", status, count))
  end
end
