local room_management = require("websockets.handlers.room_channel")[1]
local room_handler = require("websockets.handlers.room_channel")[2]
-- Main handlers table to be returned
local handlers = {
    channels = {
        room_management = room_management,
        ["room:*"] = room_handler,
        ["binary"] = require("websockets.handlers.binary_channel").binary_handler,
        ["chat:lobby"] = require("websockets.handlers.chat_channel"),
        ["chat:private"] = require("websockets.handlers.chat_channel"),
        ["game:123"] = require("websockets.handlers.game_channel"),
        ["game:456"] = require("websockets.handlers.game_channel"),
        ["dm"] = require("websockets.handlers.private_channel"), -- Dedicated channel for DMs
        ["__default__"] = require("websockets.handlers.default_channel")
    }
}

return handlers
