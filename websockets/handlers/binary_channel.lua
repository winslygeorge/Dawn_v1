local uuid = require("utils.uuid")
local binary_handler = {}

function binary_handler:message( ws, payload, state, shared)
    print("Binary message received : ", payload)
  local sender_id = state.user_id
  if not sender_id then
    return
  end

  local ws_id = shared.sockets:getSyncPrivateChatId(sender_id)

  shared.sockets:send_to_user(ws_id, {
    sender_id = sender_id,
    topic = "binary",
    receiver_id = sender_id,
    type = "dawn_reply",
    event = "message",
    payload = {
      status = "ok",
      reason = "Binary message content received.",
    },
  })

  if not payload or type(payload) ~= "string" then
    shared.sockets:send_to_user(ws, {
      type = "dawn_reply",
      event = "message",
      payload = {
        status = "error",
        reason = "Binary message content is required and must be a string.",
      },
    })
    return
  end

end

return {
  binary_handler = binary_handler,
}