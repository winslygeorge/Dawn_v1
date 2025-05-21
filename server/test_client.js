const WebSocket = require('ws');
const ws = new WebSocket('ws://localhost:8080/chat:lobby');

ws.on('open', () => {
  console.log("✅ Connected to server");

  // Join room
  ws.send(JSON.stringify({
    topic: "chat:lobby",
    event: "join",
    payload: {
      user_id: "node_user",
      token: "secret"
    }
  }));

  // Send test message after joining
  setTimeout(() => {
    ws.send(JSON.stringify({
      topic: "chat:lobby",
      event: "new_msg",
      payload: {
        body: "Hello from Node client!"
      }
    }));
  }, 1000);
});

ws.on('message', (data) => {
  console.log("📥", data.toString());
});

ws.on('close', () => {
  console.log("❌ Disconnected");
});
