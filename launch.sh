#!/bin/sh
set -eo pipefail
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
[ -f "$USERDATA_PATH/DC-flycast/debug" ] && set -x

rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1

echo "$0" "$@"
cd "$PAK_DIR" || exit 1

architecture=arm
if uname -m | grep -q '64'; then
	architecture=arm64
fi

export HOME="$USERDATA_PATH/$PAK_NAME"
export PAK_DIR="$SDCARD_PATH/Emus/$PLATFORM/DC.pak"
export FLYCAST_BIOS_DIR="$BIOS_PATH/DC/"
export FLYCAST_CONFIG_DIR="$USERDATA_PATH/DC-flycast/config/"
export FLYCAST_DATA_DIR="$USERDATA_PATH/DC-flycast/data/"
export LD_LIBRARY_PATH="$PAK_DIR/lib:$LD_LIBRARY_PATH"
export PATH="$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"

export ROM_NAME="$(basename -- "$*")"
export GAMESETTINGS_DIR="$USERDATA_PATH/DC-flycast/game-settings/$ROM_NAME"

get_sanitized_rom_name() {
	ROM_NAME="$1"
	SANITIZED_ROM_NAME="${ROM_NAME%.*}"
	echo "$SANITIZED_ROM_NAME"
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

	jq -rM '{settings: .settings}' "$PAK_DIR/config.json" >"$GAMESETTINGS_DIR/settings.json"

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

	controller_layout="$(get_controller_layout)"
	cpu_mode="$(get_cpu_mode)"
	dpad_mode="$(get_dpad_mode)"
	widescreen_mode="$(get_widescreen_mode)"

	write_settings_json

	r2_value="$(coreutils timeout .1s evtest /dev/input/event3 2>/dev/null | awk '/ABS_RZ/{getline; print}' | awk '{print $2}' || true)"
	if [ "$r2_value" = "255" ]; then
		while true; do
			minui_list_output="$(minui-list --file "$GAMESETTINGS_DIR/settings.json" --item-key "settings" --header "DC Settings" --action-button "X" --action-text "PLAY" --stdout-value state --confirm-text "CONFIRM")" || {
				exit_code="$?"
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

configure_controls() {
	controller_layout="$(get_controller_layout)"
	dpad_mode="$(get_dpad_mode)"

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

	mkdir -p "${FLYCAST_CONFIG_DIR}mappings"
	if [ "$controller_layout" = "default" ]; then
		cp -f "$PAK_DIR/config/mappings/default/SDL_Xbox 360 Controller.cfg" "${FLYCAST_CONFIG_DIR}mappings/SDL_Xbox 360 Controller.cfg"
	elif [ "$controller_layout" = "custom" ]; then
		if [ -f "$GAMESETTINGS_DIR/SDL_Xbox 360 Controller.cfg" ]; then
			cp -f "$GAMESETTINGS_DIR/SDL_Xbox 360 Controller.cfg" "${FLYCAST_CONFIG_DIR}mappings/SDL_Xbox 360 Controller.cfg"
		else
			cp -f "$PAK_DIR/config/mappings/default/SDL_Xbox 360 Controller.cfg" "${FLYCAST_CONFIG_DIR}mappings/SDL_Xbox 360 Controller.cfg"
		fi
	fi
}

configure_cpu() {
	cpu_mode="$(get_cpu_mode)"

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

	# cleanup remap
	rm -f /tmp/trimui_inputd/input_no_dpad
	rm -f /tmp/trimui_inputd/input_dpad_to_joystick
	rm -f /tmp/trimui_inputd/dpad2axis_hold_f2

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
		cp -f "${FLYCAST_CONFIG_DIR}mappings/SDL_Xbox 360 Controller.cfg" "$GAMESETTINGS_DIR/SDL_Xbox 360 Controller.cfg"
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
