#include <WiFi.h>

const char* ssid = "ESP32_CAR";
const char* password = "12345678";

WiFiServer server(80);

const int leftIn1 = 13;
const int leftIn2 = 14;
const int rightIn1 = 12;
const int rightIn2 = 11;

const int leftIn1Channel = 0;
const int leftIn2Channel = 1;
const int rightIn1Channel = 2;
const int rightIn2Channel = 3;
const int pwmFrequency = 1000;
const int pwmResolution = 8;

enum DriveCommand {
  DRIVE_STOP,
  DRIVE_FORWARD,
  DRIVE_BACKWARD,
  DRIVE_LEFT,
  DRIVE_RIGHT,
  DRIVE_FORWARD_LEFT,
  DRIVE_FORWARD_RIGHT,
  DRIVE_BACKWARD_LEFT,
  DRIVE_BACKWARD_RIGHT
};

void writeMotor(int channelForward, int channelBackward, int speedForward, int speedBackward) {
  ledcWrite(channelForward, speedForward);
  ledcWrite(channelBackward, speedBackward);
}

void allStop() {
  writeMotor(leftIn1Channel, leftIn2Channel, 0, 0);
  writeMotor(rightIn1Channel, rightIn2Channel, 0, 0);
}

void driveForward(int speed) {
  writeMotor(leftIn1Channel, leftIn2Channel, speed, 0);
  writeMotor(rightIn1Channel, rightIn2Channel, speed, 0);
}

void driveBackward(int speed) {
  writeMotor(leftIn1Channel, leftIn2Channel, 0, speed);
  writeMotor(rightIn1Channel, rightIn2Channel, 0, speed);
}

void driveLeft(int speed) {
  writeMotor(leftIn1Channel, leftIn2Channel, 0, 0);
  writeMotor(rightIn1Channel, rightIn2Channel, speed, 0);
}

void driveRight(int speed) {
  writeMotor(leftIn1Channel, leftIn2Channel, speed, 0);
  writeMotor(rightIn1Channel, rightIn2Channel, 0, 0);
}

void driveForwardLeft(int speed) {
  writeMotor(leftIn1Channel, leftIn2Channel, speed / 3, 0);
  writeMotor(rightIn1Channel, rightIn2Channel, speed, 0);
}

void driveForwardRight(int speed) {
  writeMotor(leftIn1Channel, leftIn2Channel, speed, 0);
  writeMotor(rightIn1Channel, rightIn2Channel, speed / 3, 0);
}

void driveBackwardLeft(int speed) {
  writeMotor(leftIn1Channel, leftIn2Channel, 0, speed / 3);
  writeMotor(rightIn1Channel, rightIn2Channel, 0, speed);
}

void driveBackwardRight(int speed) {
  writeMotor(leftIn1Channel, leftIn2Channel, 0, speed);
  writeMotor(rightIn1Channel, rightIn2Channel, 0, speed / 3);
}

String commandLabel(DriveCommand command) {
  switch (command) {
    case DRIVE_FORWARD:
      return "FORWARD";
    case DRIVE_BACKWARD:
      return "BACKWARD";
    case DRIVE_LEFT:
      return "LEFT";
    case DRIVE_RIGHT:
      return "RIGHT";
    case DRIVE_FORWARD_LEFT:
      return "FORWARD LEFT";
    case DRIVE_FORWARD_RIGHT:
      return "FORWARD RIGHT";
    case DRIVE_BACKWARD_LEFT:
      return "BACKWARD LEFT";
    case DRIVE_BACKWARD_RIGHT:
      return "BACKWARD RIGHT";
    case DRIVE_STOP:
    default:
      return "STOPPED";
  }
}

uint8_t extractSpeed(const String& requestLine) {
  const int marker = requestLine.indexOf("speed=");
  if (marker < 0) {
    return 255;
  }

  int end = requestLine.indexOf('&', marker);
  if (end < 0) {
    end = requestLine.indexOf(' ', marker);
  }
  if (end < 0) {
    end = requestLine.length();
  }

  const String speedValue = requestLine.substring(marker + 6, end);
  const int parsed = speedValue.toInt();
  return (uint8_t)constrain(parsed, 0, 255);
}

String extractPath(const String& requestLine) {
  const int firstSpace = requestLine.indexOf(' ');
  if (firstSpace < 0) {
    return "/";
  }

  const int secondSpace = requestLine.indexOf(' ', firstSpace + 1);
  if (secondSpace < 0) {
    return "/";
  }

  String path = requestLine.substring(firstSpace + 1, secondSpace);
  const int queryStart = path.indexOf('?');
  if (queryStart >= 0) {
    path = path.substring(0, queryStart);
  }

  return path;
}

DriveCommand pathToCommand(const String& path) {
  if (path == "/forward-left") {
    return DRIVE_FORWARD_LEFT;
  }
  if (path == "/forward-right") {
    return DRIVE_FORWARD_RIGHT;
  }
  if (path == "/backward-left") {
    return DRIVE_BACKWARD_LEFT;
  }
  if (path == "/backward-right") {
    return DRIVE_BACKWARD_RIGHT;
  }
  if (path == "/forward") {
    return DRIVE_FORWARD;
  }
  if (path == "/backward") {
    return DRIVE_BACKWARD;
  }
  if (path == "/left") {
    return DRIVE_LEFT;
  }
  if (path == "/right") {
    return DRIVE_RIGHT;
  }
  return DRIVE_STOP;
}

void applyCommand(DriveCommand command, uint8_t speed) {
  switch (command) {
    case DRIVE_FORWARD:
      driveForward(speed);
      break;
    case DRIVE_BACKWARD:
      driveBackward(speed);
      break;
    case DRIVE_LEFT:
      driveLeft(speed);
      break;
    case DRIVE_RIGHT:
      driveRight(speed);
      break;
    case DRIVE_FORWARD_LEFT:
      driveForwardLeft(speed);
      break;
    case DRIVE_FORWARD_RIGHT:
      driveForwardRight(speed);
      break;
    case DRIVE_BACKWARD_LEFT:
      driveBackwardLeft(speed);
      break;
    case DRIVE_BACKWARD_RIGHT:
      driveBackwardRight(speed);
      break;
    case DRIVE_STOP:
    default:
      allStop();
      break;
  }
}

void sendControlPage(WiFiClient& client, DriveCommand command, uint8_t speed) {
  client.println("HTTP/1.1 200 OK");
  client.println("Content-Type: text/html");
  client.println("Connection: close");
  client.println();

  client.println("<!DOCTYPE html>");
  client.println("<html><head><meta name='viewport' content='width=device-width, initial-scale=1'>");
  client.println("<style>");
  client.println("body { background:#0a0a0a; color:#efefef; text-align:center; font-family:Arial; margin:0; padding:24px; }");
  client.println("h2 { letter-spacing:1px; margin-bottom:12px; }");
  client.println(".meta { color:#b5b5b5; margin-bottom:20px; }");
  client.println(".btn { background:#171717; color:#f6f6f6; width:110px; height:110px; font-size:70px; margin:8px; border-radius:18px; border:1px solid #444; }");
  client.println(".wide { width:230px; font-size:28px; }");
  client.println("</style></head><body>");

  client.println("<h2>ESP32 CAR CONTROL</h2>");
  client.print("<div class='meta'>STATUS: ");
  client.print(commandLabel(command));
  client.print(" | SPEED: ");
  client.print(speed);
  client.println("</div>");

  client.println("<p>");
  client.println("<button class='btn' ontouchstart=\"sendCmd('/forward')\" onmousedown=\"sendCmd('/forward')\" ontouchend=\"sendCmd('/stop')\" onmouseup=\"sendCmd('/stop')\" onmouseleave=\"sendCmd('/stop')\">&uarr;</button>");
  client.println("</p>");

  client.println("<p>");
  client.println("<button class='btn' ontouchstart=\"sendCmd('/left')\" onmousedown=\"sendCmd('/left')\" ontouchend=\"sendCmd('/stop')\" onmouseup=\"sendCmd('/stop')\" onmouseleave=\"sendCmd('/stop')\">&larr;</button>");
  client.println("<button class='btn' ontouchstart=\"sendCmd('/right')\" onmousedown=\"sendCmd('/right')\" ontouchend=\"sendCmd('/stop')\" onmouseup=\"sendCmd('/stop')\" onmouseleave=\"sendCmd('/stop')\">&rarr;</button>");
  client.println("</p>");

  client.println("<p>");
  client.println("<button class='btn' ontouchstart=\"sendCmd('/backward')\" onmousedown=\"sendCmd('/backward')\" ontouchend=\"sendCmd('/stop')\" onmouseup=\"sendCmd('/stop')\" onmouseleave=\"sendCmd('/stop')\">&darr;</button>");
  client.println("</p>");

  client.println("<p><button class='btn wide' onclick=\"sendCmd('/stop')\">STOP</button></p>");

  client.println("<script>");
  client.println("function sendCmd(path) {");
  client.println("  fetch(path + '?speed=255').catch(err => console.log(err));");
  client.println("}");
  client.println("</script>");
  client.println("</body></html>");
}

void setup() {
  Serial.begin(115200);

  ledcSetup(leftIn1Channel, pwmFrequency, pwmResolution);
  ledcSetup(leftIn2Channel, pwmFrequency, pwmResolution);
  ledcSetup(rightIn1Channel, pwmFrequency, pwmResolution);
  ledcSetup(rightIn2Channel, pwmFrequency, pwmResolution);

  ledcAttachPin(leftIn1, leftIn1Channel);
  ledcAttachPin(leftIn2, leftIn2Channel);
  ledcAttachPin(rightIn1, rightIn1Channel);
  ledcAttachPin(rightIn2, rightIn2Channel);

  allStop();

  WiFi.softAP(ssid, password);
  server.begin();

  Serial.print("AP IP: ");
  Serial.println(WiFi.softAPIP());
}

void loop() {
  WiFiClient client = server.available();
  if (!client) {
    return;
  }

  const String requestLine = client.readStringUntil('\r');
  client.flush();

  const String path = extractPath(requestLine);
  const uint8_t speed = extractSpeed(requestLine);

  DriveCommand command = DRIVE_STOP;
  if (path != "/") {
    command = pathToCommand(path);
    applyCommand(command, speed);
  }

  sendControlPage(client, command, speed);
  client.stop();
}
