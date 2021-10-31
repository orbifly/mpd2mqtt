#!/bin/bash

echo "Started mpd2mqtt.sh '$0' $@"

cp /mpd2mqtt/LICENSE /data/

# Make it possible to stop by Ctrl+c in interactive container.
cleanup ()
{
  # Kill the most recent background command.
  kill -s SIGTERM $!
  exit 0
}
trap cleanup SIGINT SIGTERM

# Use some central logging functions
logfile="/data/mpd2mqtt.log"
short_logfile()
{
  if [ $( expr "$RANDOM" "%" "100" ) -lt "1" ]
  then
    if [ $( grep "." --count "${logfile}" ) -gt "1000" ]
    then
      temp_file=$( tempfile )
      tail --lines=100 "${logfile}" > ${temp_file}
      mv --force ${temp_file} ${logfile}
    fi
  fi
}

log_info()
{
  if [ "${debug}" != "0" ]
  then
    short_logfile
    echo "$1"
    date "+%x %X : $1" >> ${logfile}
  fi
}

log_error()
{
  short_logfile
  echo "$1" >&2
  date "+%x %X : $1" >> ${logfile}
}

# Default parameter setting
mpd_server="localhost"
mpd_password=""
mpd_port=""
mqtt_server="localhost"
mqtt_topic_get="music/mpd/get"
mqtt_topic_set="music/mpd/set"
mqtt_user=""
mqtt_password=""
debug="1"
if [ -f "/data/mpd2mqtt.config" ]
then
  # Read parameters from config file
  eval "$( grep --regexp="^[a-z][a-z_]*='[^']*'" "/data/mpd2mqtt.config" )"
  log_info "Read parameters from '/data/mpd2mqtt.config'"
else
  if [ -f "./example.config" ]
  then
    log_info "Create config file: /data/mpd2mqtt.config"
    cp "./example.config" "/data/mpd2mqtt.config"
  fi
fi
invalidate_file=$( tempfile )


read_parameters()
{
  while [ $# -gt 0 ]       #Solange die Anzahl der Parameter ($#) größer 0
  do
    log_info "Option: $1"
    option_name=$( echo $1 | sed "s#\(--.*=\).*\$#\1#" )
    option_value=$( echo $1 | sed "s#--.*=\(.*\)\$#\1#" )
    case "${option_name}" in
      "--mpd-server=")
        mpd_server="${option_value}"
      ;;
      "--mpd-password=")
        mpd_password="${option_value}"
      ;;
      "--mpd-port=")
        mpd_port="${option_value}"
      ;;
      "--mqtt-server=")
        mqtt_server="${option_value}"
        echo "mqtt_server = ${mqtt_server}"
      ;;
      "--mqtt-topic-get=")
        mqtt_topic_get="${option_value}"
      ;;
      "--mqtt-topic-set=")
        mqtt_topic_set="${option_value}"
      ;;
      "--mqtt_user=")
        mqtt_user="${option_value}"
      ;;
      "--mqtt_password=")
        mqtt_password="${option_value}"
      ;;
      "--debug=")
        debug="${option_value}"
      ;;
      "*")
        log_error "Unknown command line option: \"$1\""
        exit 1
      ;;
    esac
    
    shift                  #Parameter verschieben $2->$1, $3->$2, $4->$3,...
  done
}

read_parameters "$@"

if [ "${debug}" != "0" ]
then
  echo "debug = ${debug}"
  echo "mpd_server = ${mpd_server}"
  echo "mpd_password = ${mpd_password}"
  echo "mpd_port = ${mpd_port}"
  echo "mqtt_server = ${mqtt_server}"
  echo "mqtt_topic_get = ${mqtt_topic_get}"
  echo "mqtt_topic_set = ${mqtt_topic_set}"
  echo "mqtt_user = ${mqtt_user}"
  echo "mqtt_password = ${mqtt_password}"
fi

mpd_host="${mpd_server}"
if [ "${mpd_password}" != "" ]
then
  mpd_host="${mpd_password}@${mpd_server}"
fi
if [ "${mpd_port}" = "" ]
then
  mpd_port="6600"
fi
loop_for_mpd="1"

mpd_format="{
  \"name\": \"%name%\",
  \"artist\": \"%artist%\",
  \"album\": \"%album%\",
  \"albumartist\": \"%albumartist%\",
  \"comment\": \"%comment%\",
  \"composer\": \"%composer%\",
  \"date\": \"%date%\",
  \"originaldate\": \"%originaldate%\",
  \"disc\": \"%disc%\",
  \"genre\": \"%genre%\",
  \"performer\": \"%performer%\",
  \"title\": \"%title%\",
  \"track\": \"%track%\",
  \"time\": \"%time%\",
  \"file\": \"%file%\",
  \"position\": \"%position%\",
  \"id\": \"%id%\",
  \"prio\": \"%prio%\",
  \"mtime\": \"%mtime%\",
  \"mdate\": \"%mdate%\"
}"


send_to_mqtt()  #$1 = message
{
  #use a timeout to avoid a flood of waiting threads.
  timeout 10   mosquitto_pub  -h "${mqtt_server}" -t "${mqtt_topic_get}" -m "$1" -u "${mqtt_user}" -P "${mqtt_password}"
}


update_mpd_player_state()
{
  log_info "update_mpd_player_state()"
  current_song_json=$( mpc --host="${mpd_host}" --port="${mpd_port}" current --format="${mpd_format}" )
  current_state=$( mpc --host="${mpd_host}" --port="${mpd_port}" status | grep "^\[.*\]" | tail -n 1 )
  if [ "${current_state}" != "" ]
  then
    current_state=$( echo "${current_state}" | sed "s#^\[\(.*\)\].*\$#\1#" )
  else
    current_state="stopped"
  fi
  
  if [ "${debug}" != "0" ]
  then
    echo "Message:  {\"player\": { \"current\" : ${current_song_json}, \"state\": \"${current_state}\" } }"
  fi
  send_to_mqtt "{\"player\": { \"current\" : ${current_song_json}, \"state\": \"${current_state}\" } }"
}

update_mpd_playlist_state()
{
  log_info "update_mpd_playlist_state()"
  albums=$( mpc --host="${mpd_host}" --port="${mpd_port}" playlist --format "%artist% - %album%" | sort | uniq )
  album_count=$( echo "${albums}" | grep -c "..*" )
  if [ "${album_count}" = "1" ]
  then
    if [ "${debug}" != "0" ]
    then
      echo "Message:  {\"playlist\": { \"type\": \"album\", \"album\" : \"${albums}\" , \"displayName\" : \"${albums}\" } }"
    fi
    send_to_mqtt "{\"playlist\": { \"type\": \"album\", \"album\" : \"${albums}\", \"displayName\" : \"${albums}\" } }"
    return
  fi
  folders=$( mpc --host="${mpd_host}" --port="${mpd_port}" playlist --format "%file%" | sed "s#/[^/]*\$##" | sort | uniq )
  folder_count=$( echo "${folders}" | grep -c "..*" )
  if [ "${folder_count}" = "1" ]
  then
    if [ "${debug}" != "0" ]
    then
      echo "Message:  {\"playlist\": { \"type\": \"folder\", \"folder\" : \"${folder}\", \"displayName\" : \"${folders}\" } }"
    fi
    send_to_mqtt "{\"playlist\": { \"type\": \"folder\", \"folder\" : \"${folders}\", \"displayName\" : \"${folders}\" } }"
    return
  fi
  if [ "${debug}" != "0" ]
  then
    echo "Message:  {\"playlist\": { \"type\": \"unknown\", \"displayName\" : \"<mixed>\" } }"
  fi
  send_to_mqtt "{\"playlist\": { \"type\": \"unknown\", \"displayName\" : \"<mixed>\" } }"
}

update_mpd_options_state()
{
  log_info "update_mpd_options_state()"
  current_status=$( mpc --host="${mpd_host}" --port="${mpd_port}" status | grep "^volume:" | tail -n 1 )
  current_status_json=$( echo "${current_status}" | sed -e "s#\([^ ]*\): *\([^ ]*\)#\"\1\": \"\2\",#g" -e "s#^#{ \"options\": { #" -e "s#,\$# } }#" )
  if [ "${debug}" != "0" ]
  then
    echo "Message:  ${current_status_json}"
  fi
  send_to_mqtt "${current_status_json}"
}

validate_mpd_states()
{
  log_info "validate_mpd_states()"
  #Wait here to collect some invalidations. Use random to avoid to precise time overlap
  sleep "0.$( expr "100" "+" $RANDOM "%" "100" )"
  # Find entries in file. f there are delete them in a in-place operation.
  grep -c -q "player" ${invalidate_file}
  if [ "$?" = "0" ]
  then
    sed -e "/player/ d" --in-place ${invalidate_file}
    update_mpd_player_state
  fi
  grep -c -q "playlist" ${invalidate_file}
  if [ "$?" = "0" ]
  then
    sed -e "/playlist/ d" --in-place ${invalidate_file}
    update_mpd_playlist_state
  fi
  grep -c -q "options" ${invalidate_file}
  if [ "$?" = "0" ]
  then
    log_info "update_mpd_options_state"
    update_mpd_options_state
  fi
}

loop_for_mpd_change()
{
  while [ true ]
  do
    while IFS= read -r changed_topic
    do
      # Infos come up often here in a fast sequenced group. Want to prevent MQTT from flooding. We don't have mutex stuff here so use a file as queue with atomiv operations.
      case ${changed_topic} in
        "player")
          echo ${changed_topic} >> ${invalidate_file}
          validate_mpd_states &
        ;;
        "playlist")
          echo ${changed_topic} >> ${invalidate_file}
          validate_mpd_states &
        ;;
        "options")
          echo ${changed_topic} >> ${invalidate_file}
          validate_mpd_states &
        ;;
      esac
    done < <( mpc --host="${mpd_host}" --port="${mpd_port}" idleloop "player" "playlist" "options" )
    log_error "Connection to mpd lost."
    #Clean up
    rm ${invalidate_file}
    sleep 60
    log_info "Try reconnect to mpd."
  done
}

interprete_mqtt_player_command()
{
  if [ "${debug}" != "0" ]
  then
    echo "interprete_mqtt_player_command( $1 )"
  fi
  
  #strip spaces
  command=$( echo "$1" | sed -e "s#^ *##" -e "s# *\$##" )
  #strip quotes
  command=$( echo "${command}" | sed -e "s#^\"\(.*\)\"\$#\1#" )
  
  case "${command}" in
    "play")
      mpc --host="${mpd_host}" --port="${mpd_port}" "${command}"
    ;;
    "pause")
      mpc --host="${mpd_host}" --port="${mpd_port}" "${command}"
    ;;
    "toggle")
      mpc --host="${mpd_host}" --port="${mpd_port}" "${command}"
    ;;
    "playpause")
      mpc --host="${mpd_host}" --port="${mpd_port}" "toggle"
    ;;
    "stop")
      mpc --host="${mpd_host}" --port="${mpd_port}" "${command}"
    ;;
    "next")
      mpc --host="${mpd_host}" --port="${mpd_port}" "${command}"
    ;;
    "prev")
      mpc --host="${mpd_host}" --port="${mpd_port}" "${command}"
    ;;
    "update")
      mpc --host="${mpd_host}" --port="${mpd_port}" "${command}"
    ;;
    "*")
      log_error "Unknown command for options: \"${command}\" full message was \"$1\""
    ;;
  esac
}

interprete_mqtt_option_onofftoggle()
{
  if [ "${debug}" != "0" ]
  then
    echo "interprete_mqtt_option_onofftoggle( $1, $2 )"
  fi

  command_name="$2"
  command="$( echo "$1" | jq --compact-output --raw-output ".$2" )"

  if [ "${command}" = "null" ]
  then
    log_info "No option '$2'."
    return 1
  fi

  if [ "${command}" != "" ]
  then
    mpc --host="${mpd_host}" --port="${mpd_port}" "${command_name}" "${command}"
  else
    mpc --host="${mpd_host}" --port="${mpd_port}" "${command_name}"
  fi
}

interprete_mqtt_options_command()
{
  if [ "${debug}" != "0" ]
  then
    echo "interprete_mqtt_options_command( $1 )"
  fi
  
  interprete_mqtt_option_onofftoggle "$1" "random"
  interprete_mqtt_option_onofftoggle "$1" "repeat"
  interprete_mqtt_option_onofftoggle "$1" "single"
  interprete_mqtt_option_onofftoggle "$1" "consume"
  
  replaygain=$( echo "$1" | jq --compact-output --raw-output '.replaygain' )
  if [ "${replaygain}" != "null" ]
  then
    if [ "${replaygain}" != "off"  -o  "${replaygain}" != "track"  -o  "${replaygain}" != "album" ]
    then
      mpc --host="${mpd_host}" --port="${mpd_port}" "replaygain" "${replaygain}"
    else
      log_error "The option replaygain must have one of the values: 'off', 'track' or 'album'."
    fi
  fi

  volume=$( echo "$1" | jq --compact-output --raw-output '.volume' )
  if [ "${volume}" != "null" ]
  then
    wrong_chars=$( echo "${volume}" | sed "s#[+-]\?[0-9]\+##" )
    if [ "${volume}" != ""  -a  "${wrong_chars}" = "" ]
    then
      mpc --host="${mpd_host}" --port="${mpd_port}" "volume" "${volume}"
    else
      log_error "The option volume must have a value with format: '[-+]<num>'"
    fi
  fi
}

interprete_mqtt_queue_command()
{
  log_info "interprete_mqtt_queue_command( $1 )"
  del=$( echo "$1" | jq --compact-output --raw-output '.del' )
  clear=$( echo "$1" | jq --compact-output --raw-output '.clear' )
  insert=$( echo "$1" | jq --compact-output --raw-output '.insert' )
  add=$( echo "$1" | jq --compact-output --raw-output '.add' )
  play=$( echo "$1" | jq --compact-output --raw-output '.play' )
  if [ "${del}" != "null"  -a  "${del}" != "" ]
  then
    mpc --host="${mpd_host}" --port="${mpd_port}" "del" "${del}"
  fi
  if [ "${clear}" != "null"  -a  "${clear}" != "" ]
  then
    #to lower case
    clear=$( echo "${clear}" | sed "s/\([A-Z]\)/\L\1/g" )
    if [ "${clear}" = "on"  -o  "${clear}" = "yes"  -o  "${clear}" = "true"  -o  "${clear}" = "1" ]
    then
      mpc --host="${mpd_host}" --port="${mpd_port}" "clear"
    fi
  fi
  if [ "${insert}" != "null"  -a  "${insert}" != "" ]
  then
    mpc --host="${mpd_host}" --port="${mpd_port}" "insert" "${insert}"
  fi
  if [ "${add}" != "null"  -a  "${add}" != "" ]
  then
    mpc --host="${mpd_host}" --port="${mpd_port}" "add" "${add}"
  fi
  if [ "${play}" != "null"  -a  "${play}" != "" ]
  then
    #to lower case
    play=$( echo "${play}" | sed "s/\([A-Z]\)/\L\1/g" )
    if [ "${play}" = "on"  -o  "${play}" = "yes"  -o  "${play}" = "true"  -o  "${play}" = "1" ]
    then
      mpc --host="${mpd_host}" --port="${mpd_port}" "play"
    fi
  fi
}

interprete_mqtt_command()
{
  log_info "interprete_mqtt_command()"
  player=$(  echo "$1" | jq --compact-output --raw-output ".player" )
  options=$( echo "$1" | jq --compact-output --raw-output ".options" )
  queue=$( echo "$1" | jq --compact-output --raw-output ".queue" )
  log_info "player=${player}   options=${options}"

  if [ "${player}" != "null" ]
  then
    interprete_mqtt_player_command "${player}"
  fi
  if [ "${options}" != "null" ]
  then
    interprete_mqtt_options_command "${options}"
  fi
  if [ "${queue}" != "null" ]
  then
    interprete_mqtt_queue_command "${queue}"
  fi
  if [ "${player}" = "null"  -a  "${options}" = "null"  -a  "${queue}" = "null" ]
  then
    log_error "Unknown command from mqtt: \"${command_name}\" full message was \"$1\""
  fi
}

loop_for_mqtt_set()
{
  while [ true ]
  do
    while IFS= read -r line
    do
      interprete_mqtt_command "${line}" &
    done < <( mosquitto_sub -h "${mqtt_server}" -t "${mqtt_topic_set}" -u "${mqtt_user}" -P "${mqtt_password}" )
    log_error "Connection to mqtt lost."
    sleep 60
    log_info "Try reconnect to mqtt."
  done
}

mpc --host="${mpd_host}" --port="${mpd_port}" status
if [ "$?" != "0" ]
then
  log_error "Mpc got an error - exit script."
  ping "${mpd_server}" -c 1
  exit 2
fi

#MQTT test
mosquitto_pub -h "${mqtt_server}" -t "${mqtt_topic_set}" --null-message  -u "${mqtt_user}" -P "${mqtt_password}"
if [ "$?" != "0" ]
then
  log_error "Mqtt failed to test host - exit script."
  ping "${mqtt_server}" -c 1
  exit 3
fi

#send initial states to MQTT
update_mpd_player_state
update_mpd_playlist_state
update_mpd_options_state

loop_for_mpd_change &
loop_for_mqtt_set
