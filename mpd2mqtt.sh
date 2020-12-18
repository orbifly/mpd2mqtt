#!/bin/bash

echo "Started mpd2mqtt.sh '$0' $@"

mpd_server="localhost"
mpd_password=""
mpd_port=""
mqtt_server="localhost"
mqtt_topic_get="music/mpd/get"
mqtt_topic_set="music/mpd/set"
debug="1"
invalidate_file=$( tempfile )

read_parameters()
{
  while [ $# -gt 0 ]       #Solange die Anzahl der Parameter ($#) größer 0
  do
    if [ "${debug}" != "0" ]; then echo "Option: $1"; fi
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
      "--debug=")
        debug="${option_value}"
      ;;
      "*")
        echo "Unknown command line option: \"$1\"" >&2
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

update_mpd_player_state()
{
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
  mqtt pub  -h "${mqtt_server}" -t "${mqtt_topic_get}" -m "{\"player\": { \"current\" : ${current_song_json}, \"state\": \"${current_state}\" } }"
}

update_mpd_playlist_state()
{
  albums=$( mpc --host="${mpd_host}" --port="${mpd_port}" playlist --format "%artist% - %album%" | sort | uniq )
  album_count=$( echo "${albums}" | grep -c "..*" )
  if [ "${album_count}" = "1" ]
  then
    echo "Message:  {\"playlist\": { \"type\": \"album\", \"album\" : \"${albums}\" } }"
    mqtt pub  -h "${mqtt_server}" -t "${mqtt_topic_get}" -m "{\"playlist\": { \"type\": \"album\", \"album\" : \"${albums}\" } }"
    return
  fi
  folders=$( mpc --host="${mpd_host}" --port="${mpd_port}" playlist --format "%file%" | sed "s#/[^/]*\$##" | sort | uniq )
  folder_count=$( echo "${folders}" | grep -c "..*" )
  if [ "${folder_count}" = "1" ]
  then
    echo "Message:  {\"playlist\": { \"type\": \"folder\", \"folder\" : \"${folder}\" } }"
    mqtt pub  -h "${mqtt_server}" -t "${mqtt_topic_get}" -m "{\"playlist\": { \"type\": \"folder\", \"folder\" : \"${folders}\" } }"
    return
  fi
  echo "Message:  {\"playlist\": { \"type\": \"unknown\" } }"
  mqtt pub  -h "${mqtt_server}" -t "${mqtt_topic_get}" -m "{\"playlist\": { \"type\": \"unknown\" } }"
}

update_mpd_options_state()
{
  current_status=$( mpc --host="${mpd_host}" --port="${mpd_port}" status | grep "^volume:" | tail -n 1 )
  current_status_json=$( echo "${current_status}" | sed -e "s#\([^ ]*\): *\([^ ]*\)#\"\1\": \"\2\",#g" -e "s#^#{ \"options\": { #" -e "s#,\$# } }#" )
  if [ "${debug}" != "0" ]
  then
    echo "Message:  ${current_status_json}"
  fi
  mqtt pub  -h "${mqtt_server}" -t "${mqtt_topic_get}" -m "${current_status_json}"
}

validate_mpd_states()
{
  #Wait here to collect some invalidations. Use random to avoid to precise time overlap
  sleep "0.$( expr "100" "+" $RANDOM "%" "100" )"
  # Find entries in file. f there are delete them in a in-place operation.
  grep -c -q "player" ${invalidate_file}
  if [ "$?" = "0" ]
  then
    sed -e "/player/ d" --in-place ${invalidate_file}
    if [ "${debug}" != "0" ]; then echo "update_mpd_player_state"; fi
    update_mpd_player_state
  fi
  grep -c -q "playlist" ${invalidate_file}
  if [ "$?" = "0" ]
  then
    sed -e "/playlist/ d" --in-place ${invalidate_file}
    if [ "${debug}" != "0" ]; then echo "update_mpd_playlist_state ${mpd_playlist_state_valide}"; fi
    update_mpd_playlist_state
  fi
  grep -c -q "options" ${invalidate_file}
  if [ "$?" = "0" ]
  then
    sed -e "/options/ d" --in-place ${invalidate_file}
    if [ "${debug}" != "0" ]; then echo "update_mpd_options_state ${mpd_options_state_valide}"; fi
    update_mpd_options_state
  fi
}

loop_for_mpd_change()
{
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
  
  #Clean up - but we will never reach this
  rm ${invalidate_file}
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
    "*")
      echo "Unknown command for options: \"${command}\" full message was \"$1\"" >&2
    ;;
  esac
}

interprete_mqtt_options_command()
{
  if [ "${debug}" != "0" ]
  then
    echo "interprete_mqtt_options_command( $1 )"
  fi

  inner_json=$( echo "$1" | sed "s#^ *{ *\(.*\) *} *\$#\1#" )
  command_name=$( echo "${inner_json}" | sed "s#^\"\([^\"]*\)\" *:.*\$#\1#" )
  command=$( echo "${inner_json}" | sed "s#^\"${command_name}\" *:\(.*\)\$#\1#" )

  #strip spaces
  command=$( echo "${command}" | sed -e "s#^ *##" -e "s# *\$##" )
  #strip quotes
  command=$( echo "${command}" | sed -e "s#^\"\(.*\)\"\$#\1#" )
  if [ "${debug}" != "0" ]
  then
    echo "inner JSON:  ${inner_json}"
    echo "commandName:  ${command_name}"
    echo "command:  ${command}"
  fi
  
  case "${command_name}" in
    "random") #<on|off>
      if [ "${command}" != "" ]
      then
        mpc --host="${mpd_host}" --port="${mpd_port}" "${command_name}" "${command}"
      else
        mpc --host="${mpd_host}" --port="${mpd_port}" "${command_name}"
      fi
    ;;
    "repeat") #<on|off>
      if [ "${command}" != "" ]
      then
        mpc --host="${mpd_host}" --port="${mpd_port}" "${command_name}" "${command}"
      else
        mpc --host="${mpd_host}" --port="${mpd_port}" "${command_name}"
      fi
    ;;
    "replaygain") #[<off|track|album>]
      mpc --host="${mpd_host}" --port="${mpd_port}" "${command_name}" "${command}"
    ;;
    "single") #<on|off>
      if [ "${command}" != "" ]
      then
        mpc --host="${mpd_host}" --port="${mpd_port}" "${command_name}" "${command}"
      else
        mpc --host="${mpd_host}" --port="${mpd_port}" "${command_name}"
      fi
    ;;
    "volume") #[+-]<num>
      mpc --host="${mpd_host}" --port="${mpd_port}" "${command_name}" "${command}"
    ;;
    "*")
      echo "Unknown command for options: \"${command_name}\" full message was \"${inner_json}\"" >&2
    ;;
  esac
}

interprete_mqtt_command()
{
  inner_json=$( echo "$1" | sed "s#^ *{ *\(.*\) *} *\$#\1#" )
  command_name=$( echo "${inner_json}" | sed "s#^\"\([^\"]*\)\" *:.*\$#\1#" )
  command=$( echo "${inner_json}" | sed "s#^\"${command_name}\" *:\(.*\)\$#\1#" )
  if [ "${debug}" != "0" ]
  then
    echo "inner JSON:  ${inner_json}"
    echo "commandName:  ${command_name}"
    echo "command:  ${command}"
  fi
  case ${command_name} in
    "player")
      interprete_mqtt_player_command "${command}"
    ;;
    "options")
      interprete_mqtt_options_command "${command}"
    ;;
    "*")
      echo "Unknown command from mqtt: \"${command_name}\" full message was \"$1\"" >&2
    ;;
  esac
}

loop_for_mqtt_set()
{
  while IFS= read -r line
  do
    interprete_mqtt_command "${line}" &
  done < <( mqtt sub -h "${mqtt_server}" -t "${mqtt_topic_set}" )
}

mpc --host="${mpd_host}" --port="${mpd_port}" status
if [ "$?" != "0" ]
then
  echo "Mpc got an error - exit script." >&2
  ping "${mpd_host}" -c 1
  exit 2
fi

#send initial states to MQTT
update_mpd_player_state
update_mpd_playlist_state
update_mpd_options_state

loop_for_mpd_change &
loop_for_mqtt_set
