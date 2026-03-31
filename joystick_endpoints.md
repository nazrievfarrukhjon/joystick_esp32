All possible HTTP routes the app can call against your ESP32 host:

GET /
GET /forward?speed=<value>
GET /backward?speed=<value>
GET /left?speed=<value>
GET /right?speed=<value>
GET /stop?speed=<value>
Possible speed values are roughly from 51 to 255 because the slider runs from 0.2 to 1.0 and the app sends speed * 255.

Diagonal joystick actions do not use special routes. They alternate these pairs:

forward-left → GET /forward?speed=<value> and GET /left?speed=<value>
forward-right → GET /forward?speed=<value> and GET /right?speed=<value>
backward-left → GET /backward?speed=<value> and GET /left?speed=<value>
backward-right → GET /backward?speed=<value> and GET /right?speed=<value>