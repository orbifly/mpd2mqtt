# https://docs.docker.com/get-started/part2/#define-a-container-with-a-dockerfile

# Use an official image including 'apt' and 'bash' as parent
FROM debian:buster

# Upgrade and add some software we need: mpc and mqtt client
RUN apt update && apt -y upgrade; apt install -y mpc iputils-ping jq mosquitto-clients; apt autoremove -y; rm -rf /var/lib/apt/lists/*

# Set the working directory to /mpd2mqtt
WORKDIR /mpd2mqtt

# Copy needed files into the container at /mpd2mqtt
ADD ./mpd2mqtt.sh /mpd2mqtt/
ADD ./data/mpd2mqtt.config /mpd2mqtt/example.config
ADD ./LICENSE /mpd2mqtt/

VOLUME /data

# Run script when the container launches
CMD ["/mpd2mqtt/mpd2mqtt.sh"]
#Options should be set using the file 'mpd2mqtt.config' in volume '/data' - an example fill will be created on first run

#CMD ["/mpd2mqtt/mpd2mqtt.sh", "--debug=1", "--mpd-server=localhost", "--mpd-password=secret", "--mqtt-server=localhost"]
# All possible options:
# --mpd-server=
# --mpd-password=
# --mpd-port=
# --mqtt-server=
# --mqtt-topic-get=
# --mqtt-topic-set=
# --debug=     #set to 1 for some messages
