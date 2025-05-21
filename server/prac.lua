
package.path = package.path .. ";./?.lua;./../?.lua;"
require("bootstrap")
local logger = require('utils.logger').Logger:new()
local DawnServer = require("dawn_server")
local json = require('cjson')
local store = require('auth.token_store')
local dotenv = require("utils.dotenv")
local config = require("config.config")
local jwt_protect = require("auth.jwt_protect")
local refresh_handler = require("auth.refresh_handler")
local logout_handler = require("auth.logout_handler")
local jwt = require("auth.purejwt")
local rate_limiting_middleware = require('auth.rate_limiting_middleware')
logger:setLogMode("dev")
-- local in_memory_state_management = require('websockets.state_management.in_memory_state_management')
-- local wsHandlers = {
--   channels = {
--     ["__default__"] = {
--       join = function(ws, payload, state, shared, topic)
--         if not payload.token or payload.token ~= "secret" then
--           ws:send('{"error":"unauthorized"}')
--           ws:close()
--           return
--         end
--         shared.sockets:join_room(topic, ws, payload.user_id)
--         ws:send('{"status":"joined ' .. topic .. '"}')
--       end,

--       new_msg = function(ws, payload, state, shared, topic)
--         shared.sockets:broadcast_to_room(topic, {
--           topic = topic,
--           event = "new_msg",
--           payload = {
--             from = state.user_id,
--             body = payload.body
--           }
--         })
--       end
--     }
--   }
-- }



-- Optional: Forward logs somewhere (e.g., in-memory dashboard stub)
-- logger:setHook(function(batch)
--     print("📤 Hook received batch of " .. #batch .. " logs")
-- end)


-- Load the right config based on APP_ENV or fallback to dev
local settings = config.load()  -- or config.load("prod")

-- You can set APP_ENV externally or in your system:
-- export APP_ENV=prod

-- Or pass it programmatically:
dotenv.load("dev")  -- or "prod"

-- Now environment variables are loaded
local SECRET= os.getenv("SECRETE") or 'dawn_server'
local ACCESS_EXP = settings.jwt_config.access_token_expiration  -- 1 min
local REFRESH_EXP = settings.jwt_config.refresh_token_expiration   -- 1 day
local MAX_SESSION_EXP = settings.jwt_config.max_session_age
local CLEANUP_INTERVAL = settings.jwt_config.cleanup_interval
local CLEANUP_EXPIRED = settings.jwt_config.cleanup_expired
local ALLOW_MULTIPLE = settings.jwt_config.allow_multiple


-- Or use config.get for safe access:
local db_host = config.get("database").host
-- You can set APP_ENV externally or in your system:
-- export APP_ENV=prod

-- Or pass it programmatically:

store.init({
  allow_multiple = ALLOW_MULTIPLE or false,
  cleanup_expired = CLEANUP_EXPIRED or true,
  max_session_age = MAX_SESSION_EXP or 604800 ,
  cleanup_interval = CLEANUP_INTERVAL or 1800 ,-- 30 mins
  secrete = SECRET
})

-- Create a new DawnServer instance
local server = DawnServer:new({ 
  port = 8080,
  logger = logger,
  token_store = {
    store = store, cleanup_interval = CLEANUP_INTERVAL
  },  -- state_management_options = {}
})




-- Login route (issues tokens)
server:post("/login", function(req, res, body)
  local user = body.user or "guest"
  local now = os.time()

  local access_token = jwt.encode({
    sub = user,
    type = "access",
    iat = now,
    exp = now + ACCESS_EXP,
    role = "user"
  }, SECRET)

  local refresh_token = jwt.encode({
    sub = user,
    type = "refresh",
    iat = now,
    exp = now + REFRESH_EXP
  }, SECRET)

  store.save_refresh_token(user, refresh_token, {
    device_id = "laptop-123",
    ip = require('utils.uuid').v4(),
    agent = req._raw:getHeader("user-agent")
})

  server.shared_state.sessions['username'] = user

  res:writeHeader("Content-Type", "application/json")
     :writeStatus(200)
     :send(json.encode({
        access_token = access_token,
        refresh_token = refresh_token
     }))
end)

-- Refresh token
server:post("/refresh", refresh_handler({
  secret = SECRET,
  access_exp = ACCESS_EXP,
  refresh_exp = REFRESH_EXP
}))

-- Logout
server:post("/logout", logout_handler({
  secret = SECRET
}))


-- Scoped JWT middleware for all /api routes
-- server:use(jwt_protect({
--   secret = SECRET
-- }))

-- server:use(rate_limiting_middleware(), '/ws')

server:get("/sessions", function(req, res)
  local user_id = req.jwt.sub
  local sessions = store.list_sessions(user_id)

  res:writeHeader("Content-Type", "application/json")
  res:send(require("cjson").encode(sessions))
end)

-- Middleware example (global - applies to all routes)
-- server:use(function(req, res, next)
--   local log_message = string.format("[%s] %s %s", os.date("%Y-%m-%d %H:%M:%S"), req.method, req._raw:getUrl())
--   print("GLOBAL MIDDLEWARE:", log_message)
--   -- You can modify the request or response here
--   -- To proceed to the next middleware or route handler, call next()
--   next()
-- end)local jwt_protect = require("auth.jwt_protect")
-- local refresh_handler = require("auth.refresh_handler")
-- local logout_handler = require("auth.logout_handler")
-- local jwt = require("purejwt")
-- local store = require("utils.token_store")


-- server:use()

-- Middleware example (scoped - applies only to routes under /api)
-- server:use(function(req, res, next)
--   print("API SCOPED MIDDLEWARE: Checking API key...")
--   local api_key = req._raw:getHeader("X-API-Key")
--   if api_key == "secret123" then
--     next()
--   else
--     res:writeStatus(401):send("Unauthorized: Missing or invalid API key")
--   end
-- end, "/api")

-- Error handler for middleware errors
server:on_error("middleware", function(req, res, err)
  print("MIDDLEWARE ERROR HANDLER:", err)
  res:writeStatus(500):send("Internal Server Error due to middleware issue.")
end)

-- Error handler for specific route errors
server:on_route_error("/users/:id", function(req, res, err)
  print("ROUTE ERROR HANDLER for /users/:id:", err)
  res:writeStatus(500):send("Internal Server Error processing user ID.")
end)

-- GET request example (/)
server:get("/", function(req, res, query)
  print("GET / - Query Parameters:", json.encode(query))
  res:writeHeader("Content-Type", "text/plain")
     :writeHeader("Access-Control-Allow-Origin", "*")
     :writeStatus(200)
     :send("Hello, World!")
end)

-- POST request example (/data)
server:post("/data", function(req, res, body)
  print("POST /data - Body:", json.encode(body))
 
  if type(body) == "table" and body.message then
    res:writeHeader("Content-Type", "application/json")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(500)
       :send(json.encode({ received = body.message }))
  else
    res:writeHeader("Content-Type", "text/plain")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(400)
       :send("Bad Request: Missing 'message' in JSON body.")
  end
end)

-- GET request with parameters (/users/:id)
server:get("/users/:id", function(req, res, query)
  local userId = req.params.id
  print("GET /users/:id - User ID:", userId, "Query Parameters:", json.encode(query))
  if userId and tonumber(userId) then
    res:writeHeader("Content-Type", "application/json")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(200)
       :send(json.encode({ id = tonumber(userId), name = "User " .. userId }))
  else
    res:writeHeader("Content-Type", "text/plain")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(400)
       :send("Bad Request: Invalid user ID.")
  end
end)


-- PUT request with parameters and JSON body (/items/:itemId)
server:put("/items/:itemId", function(req, res, body)
  local itemId = req.params.itemId
  print("PUT /items/:itemId - Item ID:", itemId, "Body:", json.encode(body))
  if itemId and tonumber(itemId) and type(body) == "table" and body.name then
    res:writeHeader("Content-Type", "application/json")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(200)
       :send(json.encode({ updated_item = { id = tonumber(itemId), name = body.name } }))
  else
    res:writeHeader("Content-Type", "text/plain")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(400)
       :send("Bad Request: Invalid item ID or missing 'name' in JSON body.")
  end
end)

-- DELETE request with parameters (/products/:productId)
server:delete("/products/:productId", function(req, res, query)
  local productId = req.params.productId
  print("DELETE /products/:productId - Product ID:", productId, "Query Parameters:", json.encode(query))
  if productId and tonumber(productId) then
    res:writeHeader("Content-Type", "application/json")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(200)
       :send(json.encode({ deleted = tonumber(productId) }))
  else
    res:writeHeader("Content-Type", "text/plain")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(400)
       :send("Bad Request: Invalid product ID.")
  end
end)

-- PATCH request with parameters and form-urlencoded body (/settings)
server:patch("/settings", function(req, res, body)
  print("PATCH /settings - Form Data:", json.encode(body))
  if type(body) == "table" and (body.theme or body.notifications) then
    res:writeHeader("Content-Type", "application/json")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(200)
       :send(json.encode({ updated_settings = body }))
  else
    res:writeHeader("Content-Type", "text/plain")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(400)
       :send("Bad Request: Missing 'theme' or 'notifications' in form data.")
  end
end)

-- HEAD request example (/info)
server:head("/info", function(req, res, query)
  print("HEAD /info - Query Parameters:", json.encode(query))
  res:writeHeader("Content-Type", "text/plain")
     :writeHeader("Access-Control-Allow-Origin", "*")
     :writeHeader("Custom-Header", "Server-Info")
     :writeStatus(200)
     :send() -- HEAD requests should not have a body
end)

-- OPTIONS request (automatically handled by handleCORS, but you can add a specific handler if needed)
server:options("/api/resource", function(req, res, query)
  print("OPTIONS /api/resource")
  res:writeHeader("Access-Control-Allow-Origin", "*")
     :writeHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
     :writeHeader("Access-Control-Allow-Headers", "Content-Type, Authorization")
     :writeHeader("Access-Control-Max-Age", "86400")
     :writeStatus(204)
     :send()
end)

-- WebSocket route example (/ws)
server:ws("/ws", function()
end)

-- Route with wildcard (*) - matches any path under /files
server:get("/files/*", function(req, res, query)
  local filePath = req.params.splat
  print("GET /files/* - File Path:", filePath, "Query:", json.encode(query))
  -- In a real application, you would handle file serving based on filePath
  res:writeHeader("Content-Type", "text/plain")
     :writeHeader("Access-Control-Allow-Origin", "*")
     :writeStatus(200)
     :send("Serving file: " .. filePath)
end)

-- Route Scoping Example (/api routes)
server:scope("/api", function(api)
  -- These routes will be prefixed with /api
  api:get("/items", function(req, res, query)
    print("GET /api/items - Query:", json.encode(query))
    res:writeHeader("Content-Type", "application/json")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(200)
       :send(json.encode({ items = { "item1", "item2" } }))
  end)

  api:post("/items", function(req, res, body)
    print("POST /api/items - Body:", json.encode(req.body))
    if type(body) == "table" and body.name then
      res:writeHeader("Content-Type", "application/json")
         :writeHeader("Access-Control-Allow-Origin", "*")
         :writeStatus(201)
         :send(json.encode({ created = body.name }))
    else
      res:writeHeader("Content-Type", "text/plain")
         :writeHeader("Access-Control-Allow-Origin", "*")
         :writeStatus(400)
         :send("Bad Request: Missing 'name' in JSON body for /api/items.")
    end
  end)

  api:get("/users/:id", function(req, res, query)
    local userId = req.params.id
    print("GET /api/users/:id - User ID:", userId, "Query:", json.encode(query))
    res:writeHeader("Content-Type", "application/json")
       :writeHeader("Access-Control-Allow-Origin", "*")
       :writeStatus(200)
       :send(json.encode({ api_user_id = userId }))
  end)
end)

-- Edge Cases and Error Handling:

-- 1. Invalid JSON in POST/PUT/PATCH requests:
--    - The `json.decode` function in the request handler will return nil and an error message.
--    - The example handlers include checks for this and send a 400 Bad Request response.

-- 2. Missing parameters in parameterized routes:
--    - If a GET request is made to `/users/` (missing the `:id`), the router will not find a match,
--      and the server will return a 404 Not Found.

-- 3. Invalid data types for parameters:
--    - The `/users/:id` example attempts to convert `req.params.id` to a number and handles cases where it's not.

-- 4. Request to a non-existent route:
--    - The server's main request handler checks if a `handler_info` is found. If not, it returns a 404 Not Found.

-- 5. Server errors in route handlers:
--    - The `pcall` in the `handler_wrapper` catches errors that occur within the route handler function.
--    - It logs the error and then calls a route-specific error handler (if defined) or the default 500 error response.

-- 6. Server errors in middleware:
--    - The `pcall` in the `executeMiddleware` function catches errors in middleware.
--    - It logs the error and calls the global middleware error handler (if defined) or sends a default 500 error.

-- 7. Empty or malformed query parameters:
--    - The `parseQuery` function from `query_extractor` should handle empty or malformed query strings gracefully,
--      returning an empty table or the extracted parameters as best as possible.

-- 8. Requests with no body (e.g., GET, DELETE):
--    - The body parameter in the handlers for these methods will be an empty string or nil, and the example handlers
--      don't explicitly try to decode it, so they should handle this without error.

-- 9. Requests with unexpected Content-Type:
--    - The server attempts to handle `application/json`, `application/x-www-form-urlencoded`, `text/plain`, and
--      `multipart/form-data`. Requests with other content types will have their raw body passed to the handler.
--    - You might want to add specific error handling for unsupported content types if needed.

-- 10. Large request bodies (potential denial-of-service):
--     - The current code reads the entire body into memory before processing. For very large files or payloads,
--       this could lead to memory issues. Consider implementing streaming for body parsing in production
--       environments if this is a concern (the `StreamingMultipartParser` hints at this capability for multipart forms).

-- 11. Handling of invisible characters in URLs or headers:
--     - The provided code includes a `log_invisible_chars` function, which can be used for debugging purposes
--       if you suspect issues with unexpected characters in requests.

-- Start the server
server:start()