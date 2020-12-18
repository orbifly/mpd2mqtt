# mpd2mqtt #
## Connects a MPD (music player) with MQTT (broker) in both ways. ##

This can be helpfull if you want to connect a MPD with a node-red.
The connection is both-ways: If any client changes the state of MPD the MQTT will be informed. On the other hand you can operate your MPD by sending messages to MQTT broker.

## MPD -> MQTT ##
On change of the current title or toggeling between playing and pause on MPD you will get a message on MQTT a t topic *"music/mpd/get"* like:
`{"player":{"current":{"name":"","artist":"Billy Talent","album":"Billy Talent III","albumartist":"","comment":"","composer":"","date":"2009","originaldate":"%originaldate%","disc":"","genre":"","performer":"","title":"Saint Veronika","track":"","time":"4:10","file":"Alben/Billy Talent - Billy Talent III/03 - Billy Talent - Saint Veronika.mp3","position":"16","id":"67","prio":"0","mtime":"Mon Dec 27 16:42:15 2010","mdate":"12/27/10"},"state":"paused"}}`

The current options of MPD will be send in a message like:
`{"options":{"volume":"98%","repeat":"on","random":"off","single":"off","consume":"off"}}`

About the playlist/queue it's not so easy to get something out of MPD, so there could be 3 cases:
* We don't know anything about the playlist: `{"playlist":{"type":"unknown"}}`
* All songs are from the same album: `{"playlist": { "type": "album", "album" : "The Rasmus - Dead Letters" } }`
* All songs are from a common folder: `{"playlist": { "type": "folder", "folder" : "MixedMusic/preferredSongs" } }`

To debug or check it you can use the commandline mqtt client, from https://github.com/hivemq/mqtt-cli:
`mqtt sub -h localhost -t "music/mpd/get"`

## MQTT -> MPD ##
You can change the payers state by, sending something to the topic *"music/mpd/set"*.
* `{"player":"play"}`
* `{"player":"pause"}`
* `{"player":"toggle"}`

It's possible to change options by:
* `{"options": { "random": "on"} }`
* `{"options": { "replaygain": "track"} }`
* `{"options": { "volume": "+3"} }`

To debug or check it you can use the commandline mqtt client, from https://github.com/hivemq/mqtt-cli:
   `mqtt sub -h localhost -t "music/mpd/set" -m '{"player":"toggle"}'`

## How to checkout and create a docker container and run it: ##
      cd /opt
      git clone https://github.com/orbifly/mpd2mqtt.git
      cd ./mpd2mqtt/
      docker build -t mpd2mqtt .
      docker run --name my_mpd2mqtt mpd2mqtt

## Some words about security: ##
The idea for this is to make the connection between a frontend system (in my case noder-red) and a MPD backend lightweight and indirect. So it ist easy to run it on different server, just connected over MQTT. It will increase security as well, because you don't need access to a commandline from node-red (exec-node).
I tried to avoid to hand over unquoted strings from MQTT to MPD in my script. But I cannot guarantee for a security. So this software is not for any sensitive use.

## History ##
I started in 2020 with the [ct-Smart-Home](https://github.com/ct-Open-Source/ct-Smart-Home) and some zigbee devices. Now it is grown including MPD and [Lirc](https://www.lirc.org/). A lot of good stuff I found in this [article](https://www.heise.de/ct/artikel/c-t-Smart-Home-4249476.html) and some related.
