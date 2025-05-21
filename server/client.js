const socket = new WebSocket("ws://localhost:3000/ws");

socket.onopen = () => console.log("Connected!");
socket.onmessage = (event) => console.log("Message:", event.data);
socket.onerror = (error) => console.log("Error:", error);
socket.onclose = () => console.log("Disconnected!");
