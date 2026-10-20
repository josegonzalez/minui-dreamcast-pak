#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
set -x

rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1

echo "$0" "$@"
cd "$PAK_DIR" || exit 1
mkdir -p "$USERDATA_PATH/DC-flycast"

architecture=arm
if uname -m | grep -q '64'; then
	architecture=arm64
fi

# main() rewrites PLATFORM to tg5040 on h700 so the platform guard passes. Keep
# the real one around: h700 differs in the places that touch the input layer.
export BASE_PLATFORM="$PLATFORM"

# h700's built-in pad reports R2 as a digital key (NextUI workspace/h700/platform
# /platform.h, CODE_R2). tg5040 has no key event for R2 at all and reports only
# the ABS_RZ trigger axis, so the two need different hold detection.
H700_CODE_R2=315

# flycast names its mapping file after the SDL joystick name, which is "Xbox 360
# Controller" on tg5040 and "ANBERNIC-keys" on h700. The tg5040 name is also the
# one the layout this pak ships is stored under.
DEFAULT_MAPPING_FILE_NAME="SDL_Xbox 360 Controller.cfg"
MAPPING_FILE_NAME="$DEFAULT_MAPPING_FILE_NAME"
if [ "$BASE_PLATFORM" = "h700" ]; then
	MAPPING_FILE_NAME="SDL_ANBERNIC-keys.cfg"
fi

export HOME="$USERDATA_PATH/DC-flycast"
export PAK_DIR="$SDCARD_PATH/Emus/$PLATFORM/DC.pak"
export FLYCAST_BIOS_DIR="$BIOS_PATH/DC/"
export FLYCAST_CONFIG_DIR="$USERDATA_PATH/DC-flycast/config/"
export FLYCAST_DATA_DIR="$USERDATA_PATH/DC-flycast/data/"
export LD_LIBRARY_PATH="$PAK_DIR/lib:$LD_LIBRARY_PATH"
export PATH="$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"

# recorded because h700 behaviour depends on the model, and set -x does not
# expand the case word that reads it
echo "DC.pak: base_platform=$BASE_PLATFORM model=$RGXX_MODEL architecture=$architecture" >&2

export ROM_NAME="$(basename -- "$*")"
export GAMESETTINGS_DIR="$USERDATA_PATH/DC-flycast/game-settings/$ROM_NAME"

get_sanitized_rom_name() {
	ROM_NAME="$1"
	SANITIZED_ROM_NAME="${ROM_NAME%.*}"
	echo "$SANITIZED_ROM_NAME"
}

# Analog stick per h700 SKU, mirroring NextUI's own detection. Without a stick
# there is nothing to swap the dpad with.
#
# NextUI reports the model twice and in two different cases: RGXX_MODEL is upper
# case ("RGSP") while DEVICE is lower ("rgsp"). Normalize before matching.
h700_has_lstick() {
	model="$(echo "${RGXX_MODEL:-$DEVICE}" | tr '[:upper:]' '[:lower:]')"

	case "$model" in
	rg34xxsp | rg35xxh | rg35xxpro | rg40xxh | rg40xxv | rgcubexx)
		return 0
		;;
	esac

	return 1
}

# gptokeyb2 creates a keyboard and a mouse, and has renamed the keyboard
# between releases ("Fake Keyboard" before 2.00.03, "Fake Keyboard Mouse"
# after), so match on the prefix and ignore the mouse.
find_fake_keyboard_node() {
	for node in /dev/input/event*; do
		if [ ! -e "$node" ]; then
			continue
		fi
		name="$(cat "/sys/class/input/$(basename "$node")/device/name" 2>/dev/null || true)"
		case "$name" in
		"Fake Keyboard"*)
			echo "$node"
			return
			;;
		esac
	done
}

# Mirror the dpad onto arrow keys so flycast's own menu stays navigable while
# the dpad is driving the Dreamcast analog stick. imgui moves between items on
# dpad or arrow keys only, and a model with no analog stick has nothing else
# left to offer it.
#
# gptokeyb2 reads the pad through SDL and writes the arrow keys to a uinput
# keyboard. It never grabs the pad, so flycast keeps receiving the dpad as well.
#
# NextUI's SDL is built without libudev, so SDL_EVDEV opens no keyboard at all
# unless SDL_EVDEV_DEVICES names one. The 2 is SDL_UDEV_DEVICE_KEYBOARD.
start_dpad_keyboard() {
	if ! command -v gptokeyb2 >/dev/null 2>&1; then
		return 1
	fi

	# A session killed hard enough to skip cleanup leaves gptokeyb2 and its
	# uinput device behind. Clear those out first, and wait for the node to go
	# with them, so the lookup below cannot settle on an orphan's device
	# instead: they share a name.
	stop_dpad_keyboard
	tries=0
	while [ -n "$(find_fake_keyboard_node)" ] && [ "$tries" -lt 20 ]; do
		tries=$((tries + 1))
		coreutils sleep .1
	done

	# the program name is what gptokeyb2 watches to know when to stop
	gptokeyb2 flycast -c "$PAK_DIR/config/dpad-arrows.gptk" >/dev/null 2>&1 &

	# wait for its uinput device to appear, then point SDL at it
	tries=0
	while [ "$tries" -lt 20 ]; do
		node="$(find_fake_keyboard_node)"
		if [ -n "$node" ]; then
			export SDL_EVDEV_DEVICES="2:$node"
			return 0
		fi
		tries=$((tries + 1))
		coreutils sleep .1
	done

	stop_dpad_keyboard
	return 1
}

# SIGKILL, because SDL_Init turns SIGTERM into an SDL_QUIT event that gptokeyb2
# never handles, so it ignores a polite kill. This is what gptokeyb2's own
# README does ("kill -9 $(pidof gptokeyb2)"), and the kernel tears down its
# uinput devices when the process dies, so nothing is left behind.
stop_dpad_keyboard() {
	killall -9 gptokeyb2 >/dev/null 2>&1 || true
}

# flycast's built-in keyboard mapping binds the arrow keys to the Dreamcast
# dpad (KeyboardInputMapping in keyboard_device.h), so a mirrored dpad would
# drive the analog stick and the dpad at once. Give the keyboard a mapping with
# no bindings instead. imgui still sees the keys, because gui_keyboard_key runs
# whatever the mapping says, but nothing reaches the Dreamcast.
#
# Written only while the mirror is running and removed otherwise, because the
# config directory is shared by every game.
keyboard_mapping_file() {
	echo "${FLYCAST_CONFIG_DIR}mappings/SDL_Keyboard.cfg"
}

write_neutral_keyboard_mapping() {
	cat >"$(keyboard_mapping_file)" <<-NEUTRAL
		[emulator]
		dead_zone = 10
		mapping_name = DC.pak neutral keyboard
		rumble_power = 100
		saturation = 100
		version = 3
	NEUTRAL
}

remove_neutral_keyboard_mapping() {
	mapping_file="$(keyboard_mapping_file)"
	if [ ! -f "$mapping_file" ]; then
		return
	fi

	# only ever remove the one this pak wrote, never a keyboard mapping the
	# user made for a keyboard of their own
	if ! grep -q "^mapping_name = DC.pak neutral keyboard$" "$mapping_file"; then
		return
	fi

	rm -f "$mapping_file"
}

# Is R2 being held right now? Used to decide whether to open the settings menu.
is_r2_held() {
	if [ "$BASE_PLATFORM" = "h700" ]; then
		# evtest --query reads the current key state via EVIOCGKEY and exits 10
		# when the key is down. The pad is not always on the same node, so ask
		# every node.
		for node in /dev/input/event*; do
			if [ ! -e "$node" ]; then
				continue
			fi

			query_status=0
			evtest --query "$node" EV_KEY "$H700_CODE_R2" >/dev/null 2>&1 || query_status="$?"
			if [ "$query_status" -eq 10 ]; then
				return 0
			fi
		done

		return 1
	fi

	r2_value="$(coreutils timeout .1s evtest /dev/input/event3 2>/dev/null | awk '/ABS_RZ/{getline; print}' | awk '{print $2}' || true)"
	[ "$r2_value" = "255" ]
}

get_controller_layout() {
	controller_layout="default"
	if [ -f "$GAMESETTINGS_DIR/controller-layout" ]; then
		controller_layout="$(cat "$GAMESETTINGS_DIR/controller-layout")"
	fi
	if [ -f "$GAMESETTINGS_DIR/controller-layout.tmp" ]; then
		controller_layout="$(cat "$GAMESETTINGS_DIR/controller-layout.tmp")"
	fi

	echo "$controller_layout"
}

get_cpu_mode() {
	cpu_mode="performance"
	if [ -f "$GAMESETTINGS_DIR/cpu-mode" ]; then
		cpu_mode="$(cat "$GAMESETTINGS_DIR/cpu-mode")"
	fi
	if [ -f "$GAMESETTINGS_DIR/cpu-mode.tmp" ]; then
		cpu_mode="$(cat "$GAMESETTINGS_DIR/cpu-mode.tmp")"
	fi
	echo "$cpu_mode"
}

get_dpad_mode() {
	dpad_mode="dpad"
	if [ -f "$GAMESETTINGS_DIR/dpad-mode" ]; then
		dpad_mode="$(cat "$GAMESETTINGS_DIR/dpad-mode")"
	fi
	if [ -f "$GAMESETTINGS_DIR/dpad-mode.tmp" ]; then
		dpad_mode="$(cat "$GAMESETTINGS_DIR/dpad-mode.tmp")"
	fi

	if [ "$dpad_mode" = "f2" ]; then
		dpad_mode="joystick-on-f2"
	fi

	# h700 has no trimui_inputd, so the modes that need it behave as "joystick",
	# which the pak applies inside the flycast mapping instead
	if [ "$BASE_PLATFORM" = "h700" ] && [ "$dpad_mode" != "dpad" ]; then
		dpad_mode="joystick"
	fi

	echo "$dpad_mode"
}

get_widescreen_mode() {
	widescreen_mode="off"
	if [ -f "$GAMESETTINGS_DIR/widescreen-mode" ]; then
		widescreen_mode="$(cat "$GAMESETTINGS_DIR/widescreen-mode")"
	fi
	if [ -f "$GAMESETTINGS_DIR/widescreen-mode.tmp" ]; then
		widescreen_mode="$(cat "$GAMESETTINGS_DIR/widescreen-mode.tmp")"
	fi
	echo "$widescreen_mode"
}

write_settings_json() {
	# name: Controller Layout
	controller_layout="$(get_controller_layout)"
	# name: CPU Mode
	cpu_mode="$(get_cpu_mode)"
	# name: DPAD Mode
	dpad_mode="$(get_dpad_mode)"
	# name: Widescreen Mode
	widescreen_mode="$(get_widescreen_mode)"

	jq -rM '{settings: .settings}' "$PAK_DIR/settings.json" >"$GAMESETTINGS_DIR/settings.json"

	# h700 cannot apply the two modes that need trimui_inputd, so do not offer
	# them. This has to happen before the update_setting_key calls below, which
	# resolve "selected" against the options list.
	if [ "$BASE_PLATFORM" = "h700" ]; then
		# shellcheck disable=SC2016
		jq -rM --argjson options '["dpad", "joystick"]' '
			.settings |= map(if .name == "DPAD Mode" then . + {"options": $options} else . end)
		' "$GAMESETTINGS_DIR/settings.json" >"$GAMESETTINGS_DIR/settings.json.tmp"
		mv -f "$GAMESETTINGS_DIR/settings.json.tmp" "$GAMESETTINGS_DIR/settings.json"
	fi

	update_setting_key "$GAMESETTINGS_DIR/settings.json" "Controller Layout" "$controller_layout"
	update_setting_key "$GAMESETTINGS_DIR/settings.json" "CPU Mode" "$cpu_mode"
	update_setting_key "$GAMESETTINGS_DIR/settings.json" "DPAD Mode" "$dpad_mode"
	update_setting_key "$GAMESETTINGS_DIR/settings.json" "Widescreen Mode" "$widescreen_mode"
	sync
}

# the settings.json file contains a "settings" array
# we have a series of settings that we need to update based on the values above
# for each setting, we need to find the index of the setting where the setting's name key matches the name above
# then we need to find the index of the option in the setting's options array that matches the value above
# and finally we need to update the setting's selected key to the index of the option
# the final settings.json should have a "settings" array, where each of the settings has an updated selected key
update_setting_key() {
	settings_file="$1"
	setting_name="$2"
	option_value="$3"

	# fetch the option index
	jq --arg name "$setting_name" --arg option "$option_value" '
 		.settings |= map(if .name == $name then . + {"selected": ((.options // []) | index($option) // -1)} else . end)
	' "$settings_file" >"$settings_file.tmp"
	mv -f "$settings_file.tmp" "$settings_file"
}

settings_menu() {
	mkdir -p "$GAMESETTINGS_DIR"

	rm -f "$GAMESETTINGS_DIR/controller-layout.tmp"
	rm -f "$GAMESETTINGS_DIR/cpu-mode.tmp"
	rm -f "$GAMESETTINGS_DIR/dpad-mode.tmp"
	rm -f "$GAMESETTINGS_DIR/widescreen-mode.tmp"
	rm -f "$GAMESETTINGS_DIR/minui-list-output.json"

	controller_layout="$(get_controller_layout)"
	cpu_mode="$(get_cpu_mode)"
	dpad_mode="$(get_dpad_mode)"
	widescreen_mode="$(get_widescreen_mode)"

	write_settings_json

	if is_r2_held; then
		while true; do
			minui-list --disable-auto-sleep --file "$GAMESETTINGS_DIR/settings.json" --item-key "settings" --title "DC Settings" --action-button "X" --action-text "PLAY" --write-value state --write-location "$GAMESETTINGS_DIR/minui-list-output.json" --confirm-text "CONFIRM" || {
				exit_code="$?"
				minui_list_output="$(cat "$GAMESETTINGS_DIR/minui-list-output.json")"
				# 4 = action button
				# we break out of the loop because the action button is the play button
				if [ "$exit_code" -eq 4 ]; then
					# shellcheck disable=SC2016
					echo "$minui_list_output" | jq -r --arg name "Controller Layout" '.settings[] | select(.name == $name) | .options[.selected]' >"$GAMESETTINGS_DIR/controller-layout.tmp"
					# shellcheck disable=SC2016
					echo "$minui_list_output" | jq -r --arg name "CPU Mode" '.settings[] | select(.name == $name) | .options[.selected]' >"$GAMESETTINGS_DIR/cpu-mode.tmp"
					# shellcheck disable=SC2016
					echo "$minui_list_output" | jq -r --arg name "DPAD Mode" '.settings[] | select(.name == $name) | .options[.selected]' >"$GAMESETTINGS_DIR/dpad-mode.tmp"
					# shellcheck disable=SC2016
					echo "$minui_list_output" | jq -r --arg name "Widescreen Mode" '.settings[] | select(.name == $name) | .options[.selected]' >"$GAMESETTINGS_DIR/widescreen-mode.tmp"

					break
				fi

				# 2 = back button, 3 = menu button
				# both are errors, so we exit with the exit code
				if [ "$exit_code" -ne 0 ]; then
					exit "$exit_code"
				fi
			}

			minui_list_output="$(cat "$GAMESETTINGS_DIR/minui-list-output.json")"
			selected_index="$(echo "$minui_list_output" | jq -r ' .selected')"
			# 5 = Re-apply default emulator settings
			if [ "$selected_index" -eq 5 ]; then
				show_message "Re-applying default flycast settings" 2
				mkdir -p "$FLYCAST_CONFIG_DIR"
				cp -f "$PAK_DIR/config/emu.cfg" "${FLYCAST_CONFIG_DIR}emu.cfg"
				sync
				continue
			fi

			show_message "Saving settings for game" 2
			# fetch values for next loop
			controller_layout="$(echo "$minui_list_output" | jq -r --arg name "Controller Layout" '.settings[] | select(.name == $name) | .options[.selected]')"
			cpu_mode="$(echo "$minui_list_output" | jq -r --arg name "CPU Mode" '.settings[] | select(.name == $name) | .options[.selected]')"
			dpad_mode="$(echo "$minui_list_output" | jq -r --arg name "DPAD Mode" '.settings[] | select(.name == $name) | .options[.selected]')"
			widescreen_mode="$(echo "$minui_list_output" | jq -r --arg name "Widescreen Mode" '.settings[] | select(.name == $name) | .options[.selected]')"

			# save values to disk
			echo "$minui_list_output" >"$GAMESETTINGS_DIR/settings.json"
			echo "$controller_layout" >"$GAMESETTINGS_DIR/controller-layout"
			echo "$cpu_mode" >"$GAMESETTINGS_DIR/cpu-mode"
			echo "$dpad_mode" >"$GAMESETTINGS_DIR/dpad-mode"
			echo "$widescreen_mode" >"$GAMESETTINGS_DIR/widescreen-mode"
			sync
		done
	fi
}

configure_platform() {
	# ensure config and data directories and files exist
	mkdir -p "$FLYCAST_CONFIG_DIR" "$FLYCAST_DATA_DIR"
	if [ ! -f "${FLYCAST_CONFIG_DIR}emu.cfg" ]; then
		cp -f "$PAK_DIR/config/emu.cfg" "${FLYCAST_CONFIG_DIR}emu.cfg"
	fi

	# migrate non-bios files are moved to the $FLYCAST_DATA_DIR
	cd "$FLYCAST_BIOS_DIR" || exit 1
	if [ -d "boxart" ]; then
		mv boxart "${FLYCAST_DATA_DIR}boxart"
	fi
	if [ -f dc_nvmem.bin ]; then
		mv dc_nvmem.bin "${FLYCAST_DATA_DIR}dc_nvmem.bin"
	fi
	if [ -f vmu_save_A1.bin ]; then
		mv vmu_save_A1.bin "${FLYCAST_DATA_DIR}vmu_save_A1.bin"
	fi
	if [ -f vmu_save_A2.bin ]; then
		mv vmu_save_A2.bin "${FLYCAST_DATA_DIR}vmu_save_A2.bin"
	fi

	for file in *.state; do
		if [ ! -f "$file" ]; then
			continue
		fi
		mv "$file" "${FLYCAST_DATA_DIR}"
	done
	cd "$PAK_DIR" || exit 1

	sync
}

# h700 has no trimui_inputd, so "joystick" is applied inside the flycast mapping
# instead. Only the hat is rewritten, named by flycast's own key codes 256-259,
# so a button someone bound to the Dreamcast dpad themselves is left alone and
# the pair below is exactly reversible, which revert_h700_dpad_mode() needs.
map_dpad_to_analog() {
	sed -i \
		-e "s/= 256:btn_dpad1_up/= 256:btn_analog_up/" \
		-e "s/= 257:btn_dpad1_down/= 257:btn_analog_down/" \
		-e "s/= 258:btn_dpad1_left/= 258:btn_analog_left/" \
		-e "s/= 259:btn_dpad1_right/= 259:btn_analog_right/" \
		"$1"
}

unmap_dpad_from_analog() {
	sed -i \
		-e "s/= 256:btn_analog_up/= 256:btn_dpad1_up/" \
		-e "s/= 257:btn_analog_down/= 257:btn_dpad1_down/" \
		-e "s/= 258:btn_analog_left/= 258:btn_dpad1_left/" \
		-e "s/= 259:btn_analog_right/= 259:btn_dpad1_right/" \
		"$1"
}

# On a model with a stick the two are exchanged, so the stick still drives the
# Dreamcast dpad and flycast's own menu stays navigable.
#
# The first stick has two spellings: the v3 "axis_left" that flycast writes
# itself, and the "btn_analog_left" compat name this pak ships. Normalize onto
# the compat name so that applying the swap twice restores the original mapping,
# which revert_h700_dpad_mode() relies on.
#
# Unlike the pair above this matches on the bind name alone, and must keep doing
# so: anchoring it to the hat codes stops two passes from restoring the original,
# because the stick binds live on axes whose numbers this cannot know.
swap_dpad_and_stick() {
	mapping_file="$1"

	for direction in up down left right; do
		sed -i \
			-e "s/:axis_$direction/:btn_analog_$direction/" \
			-e "s/:btn_analog_$direction/:__stick_$direction/" \
			-e "s/:btn_dpad1_$direction/:btn_analog_$direction/" \
			-e "s/:__stick_$direction/:btn_dpad1_$direction/" \
			"$mapping_file"
	done
}

apply_h700_dpad_mode() {
	if h700_has_lstick; then
		swap_dpad_and_stick "$1"
	else
		map_dpad_to_analog "$1"

		# with no stick left to drive the Dreamcast dpad, mirror the dpad onto
		# the arrow keys so flycast's own menu can still be navigated
		if start_dpad_keyboard; then
			write_neutral_keyboard_mapping
		else
			show_message "DPAD is the analog stick. The flycast menu cannot be navigated in this mode." 2
		fi
	fi
}

revert_h700_dpad_mode() {
	if h700_has_lstick; then
		swap_dpad_and_stick "$1"
	else
		unmap_dpad_from_analog "$1"
	fi
}

configure_controls() {
	controller_layout="$(get_controller_layout)"
	dpad_mode="$(get_dpad_mode)"

	# trimui_inputd is Trimui's input daemon, which exists only on tg5040
	if [ "$BASE_PLATFORM" != "h700" ]; then
		if [ "$dpad_mode" = "joystick-on-f2" ]; then
			mkdir -p /tmp/trimui_inputd/
			touch /tmp/trimui_inputd/dpad2axis_hold_f2
		elif [ "$dpad_mode" = "joystick-and-dpad" ]; then
			mkdir -p /tmp/trimui_inputd/
			touch /tmp/trimui_inputd/input_dpad_to_joystick
		elif [ "$dpad_mode" = "joystick" ]; then
			mkdir -p /tmp/trimui_inputd/
			touch /tmp/trimui_inputd/input_no_dpad
			touch /tmp/trimui_inputd/input_dpad_to_joystick
		fi
	fi

	mkdir -p "${FLYCAST_CONFIG_DIR}mappings"
	if [ "$controller_layout" = "default" ]; then
		cp -f "$PAK_DIR/config/mappings/default/$DEFAULT_MAPPING_FILE_NAME" "${FLYCAST_CONFIG_DIR}mappings/$MAPPING_FILE_NAME"
	elif [ "$controller_layout" = "custom" ]; then
		if [ -f "$GAMESETTINGS_DIR/$MAPPING_FILE_NAME" ]; then
			cp -f "$GAMESETTINGS_DIR/$MAPPING_FILE_NAME" "${FLYCAST_CONFIG_DIR}mappings/$MAPPING_FILE_NAME"
		else
			cp -f "$PAK_DIR/config/mappings/default/$DEFAULT_MAPPING_FILE_NAME" "${FLYCAST_CONFIG_DIR}mappings/$MAPPING_FILE_NAME"
		fi
	fi

	# never leave the neutral keyboard mapping behind for a mode that does not
	# use the dpad mirror
	if [ "$BASE_PLATFORM" = "h700" ]; then
		remove_neutral_keyboard_mapping
	fi

	if [ "$BASE_PLATFORM" = "h700" ] && [ "$dpad_mode" = "joystick" ]; then
		apply_h700_dpad_mode "${FLYCAST_CONFIG_DIR}mappings/$MAPPING_FILE_NAME"
	fi
}

configure_cpu() {
	cpu_mode="$(get_cpu_mode)"

	cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor >"$HOME/cpu_governor.txt"
	cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq >"$HOME/cpu_min_freq.txt"
	cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq >"$HOME/cpu_max_freq.txt"

	if [ "$cpu_mode" = "performance" ]; then
		echo performance >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
		echo 1608000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq
		echo 1800000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
	else
		echo ondemand >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
		echo 1200000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq
		echo 1800000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
	fi
}

configure_widescreen() {
	widescreen_mode="$(get_widescreen_mode)"

	# modify ${FLYCAST_CONFIG_DIR}emu.cfg
	# set rend.WideScreen to yes if widescreen_mode is on
	# set rend.WidescreenGameHacks to yes if widescreen_cheat_mode is on
	if [ "$widescreen_mode" = "on" ] || [ "$widescreen_mode" = "cheat" ]; then
		sed -i 's/rend.WideScreen = .*/rend.WideScreen = yes/' "${FLYCAST_CONFIG_DIR}emu.cfg"
	fi
	if [ "$widescreen_mode" = "cheat" ]; then
		sed -i 's/rend.WidescreenGameHacks = .*/rend.WidescreenGameHacks = yes/' "${FLYCAST_CONFIG_DIR}emu.cfg"
	fi
}

restore_save_states_for_game() {
	SANITIZED_ROM_NAME="$(get_sanitized_rom_name "$ROM_NAME")"
	mkdir -p "$FLYCAST_DATA_DIR" "$SHARED_USERDATA_PATH/DC-flycast"

	# check and copy platform-specific state files that already exist
	# this may happen if the game was saved on the device but we lost power before
	# we could restore them to the normal MinUI paths
	if [ -f "${FLYCAST_DATA_DIR}${SANITIZED_ROM_NAME}.state" ]; then
		cd "$FLYCAST_DATA_DIR" || exit 1
		for file in *.state; do
			if [ ! -f "$file" ]; then
				continue
			fi
			mv "$file" "$SHARED_USERDATA_PATH/DC-flycast/"
		done
		cd "$PAK_DIR" || exit 1
	fi

	# state files are the save states and should be restored from SHARED_USERDATA_PATH/DC-flycast/
	if [ -f "$SHARED_USERDATA_PATH/DC-flycast/$SANITIZED_ROM_NAME.state" ]; then
		cp -f "$SHARED_USERDATA_PATH/DC-flycast/$SANITIZED_ROM_NAME.state" "${FLYCAST_DATA_DIR}${SANITIZED_ROM_NAME}.state"
	fi

	if [ -f "/tmp/resume_slot.txt" ]; then
		save_state="$(xargs <"/tmp/resume_slot.txt")"
		if [ "$save_state" -eq 0 ] && [ -f "${FLYCAST_DATA_DIR}${SANITIZED_ROM_NAME}.state" ]; then
			sed -i 's/Dreamcast.AutoLoadState = .*/Dreamcast.AutoLoadState = yes/' "${FLYCAST_CONFIG_DIR}emu.cfg"
		fi
	fi

	touch /tmp/dc-saves-restored

	sync
}

show_message() {
	message="$1"
	seconds="$2"

	if [ -z "$seconds" ]; then
		seconds="forever"
	fi

	killall minui-presenter >/dev/null 2>&1 || true
	echo "$message" 1>&2
	if [ "$seconds" = "forever" ]; then
		minui-presenter --message "$message" --timeout -1 &
	else
		minui-presenter --message "$message" --timeout "$seconds"
	fi
}

cleanup() {
	SANITIZED_ROM_NAME="$(get_sanitized_rom_name "$ROM_NAME")"

	rm -f /tmp/stay_awake
	killall minui-presenter >/dev/null 2>&1 || true

	if [ -f "$HOME/cpu_governor.txt" ]; then
		cat "$HOME/cpu_governor.txt" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
		rm -f "$HOME/cpu_governor.txt"
	fi
	if [ -f "$HOME/cpu_min_freq.txt" ]; then
		cat "$HOME/cpu_min_freq.txt" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq
		rm -f "$HOME/cpu_min_freq.txt"
	fi
	if [ -f "$HOME/cpu_max_freq.txt" ]; then
		cat "$HOME/cpu_max_freq.txt" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
		rm -f "$HOME/cpu_max_freq.txt"
	fi

	stop_dpad_keyboard
	if [ "$BASE_PLATFORM" = "h700" ]; then
		remove_neutral_keyboard_mapping
	fi

	# cleanup remap
	if [ "$BASE_PLATFORM" != "h700" ]; then
		rm -f /tmp/trimui_inputd/input_no_dpad
		rm -f /tmp/trimui_inputd/input_dpad_to_joystick
		rm -f /tmp/trimui_inputd/dpad2axis_hold_f2
	fi

	# remove resume slot
	rm -f /tmp/resume_slot.txt

	# do not touch the resume slot if the saves were not restored
	if [ -f "/tmp/dc-saves-restored" ]; then
		mkdir -p "$SHARED_USERDATA_PATH/.minui/DC"
		# create the resume slot if st0 exists
		if [ -f "${FLYCAST_DATA_DIR}${SANITIZED_ROM_NAME}.state" ]; then
			echo "0" >"$SHARED_USERDATA_PATH/.minui/DC/$ROM_NAME.txt"
		else
			rm -f "$SHARED_USERDATA_PATH/.minui/DC/$ROM_NAME.txt"
		fi
	fi
	rm -f /tmp/dc-saves-restored

	mkdir -p "$SHARED_USERDATA_PATH/DC-flycast"
	cd "$FLYCAST_DATA_DIR" || exit 1
	for file in *.state; do
		if [ ! -f "$file" ]; then
			continue
		fi
		mv "$file" "$SHARED_USERDATA_PATH/DC-flycast/"
	done
	cd "$PAK_DIR" || exit 1

	# rename any screenshots to include the rom name
	if [ -d "$SDCARD_PATH/Screenshots" ]; then
		cd "$SDCARD_PATH/Screenshots" || exit 1
		for file in *.png; do
			if [ ! -f "$file" ]; then
				continue
			fi
			# only handle files that start with "Flycast-"
			if ! echo "$file" | grep -q "^Flycast-"; then
				continue
			fi

			# replace the word "Flycast" with the rom name
			screenshot_name="$(echo "$file" | sed "s/Flycast/$SANITIZED_ROM_NAME/g")"
			mv "$file" "$SDCARD_PATH/Screenshots/$screenshot_name"
		done
		cd "$PAK_DIR" || exit 1
	fi

	controller_layout="$(get_controller_layout)"
	if [ "$controller_layout" = "custom" ]; then
		mkdir -p "$GAMESETTINGS_DIR"
		cp -f "${FLYCAST_CONFIG_DIR}mappings/$MAPPING_FILE_NAME" "$GAMESETTINGS_DIR/$MAPPING_FILE_NAME"

		# the mode is layered on top of the saved mapping, so undo it before
		# saving, or the next launch would apply it to a mapping that has it
		# already and switching back to "dpad" would leave the dpad on the stick
		if [ "$BASE_PLATFORM" = "h700" ] && [ "$(get_dpad_mode)" = "joystick" ]; then
			revert_h700_dpad_mode "$GAMESETTINGS_DIR/$MAPPING_FILE_NAME"
		fi
	fi

	sync
}

main() {
	echo "1" >/tmp/stay_awake
	trap "cleanup" EXIT INT TERM HUP QUIT

	if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
		export DEVICE="brick"
		export PLATFORM="tg5040"
	fi


	#H700 specific - additional libraries
	if [ "$PLATFORM" = "h700" ]; then
		export LD_LIBRARY_PATH="$PAK_DIR/lib_h700:$LD_LIBRARY_PATH"
		export PLATFORM="tg5040"
	fi


	if [ "$PLATFORM" != "tg5040" ]; then
		show_message "$PLATFORM is not a supported platform" 2
		exit 1
	fi

	if ! command -v minui-presenter >/dev/null 2>&1; then
		show_message "minui-presenter not found" 2
		return 1
	fi

	mkdir -p "$GAMESETTINGS_DIR"

	# migrate the old bios directory
	if [ -f "$BIOS_PATH/dc" ]; then
		mv "$BIOS_PATH/dc" "$BIOS_PATH/dreamcast"
		mv "$BIOS_PATH/dreamcast" "$BIOS_PATH/DC"
		sync
	fi

	if [ ! -f "${FLYCAST_BIOS_DIR}dc_boot.bin" ]; then
		show_message "Missing /BIOS/DC/dc_boot.bin" 2
		exit 1
	fi

	if [ ! -f "${FLYCAST_BIOS_DIR}naomi.zip" ]; then
		show_message "Missing /BIOS/DC/naomi.zip" 2
		exit 1
	fi

	settings_menu
	configure_platform
	configure_controls
	configure_cpu
	configure_widescreen
	restore_save_states_for_game

	flycast "$@"
}

main "$@"
