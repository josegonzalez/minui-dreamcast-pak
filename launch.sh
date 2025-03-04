#!/bin/sh
set -eo pipefail
[ -f "$USERDATA_PATH/DC-flycast/debug" ] && set -x

rm -f "$LOGS_PATH/DC.txt"
exec >>"$LOGS_PATH/DC.txt"
exec 2>&1

echo $0 $*
echo "1" >/tmp/stay_awake

export PAK_DIR="$SDCARD_PATH/Emus/$PLATFORM/DC.pak"
export FLYCAST_BIOS_DIR="$BIOS_PATH/DC/"
export FLYCAST_CONFIG_DIR="$USERDATA_PATH/DC-flycast/config/"
export FLYCAST_DATA_DIR="$USERDATA_PATH/DC-flycast/data/"
export LD_LIBRARY_PATH="$PAK_DIR/lib:$LD_LIBRARY_PATH"
export PATH="$PAK_DIR/bin:$PATH"

export ROM_NAME="$(basename -- "$*")"
export GAMESETTINGS_DIR="$USERDATA_PATH/DC-flycast/game-settings/$ROM_NAME"

get_sanitized_rom_name() {
	ROM_NAME="$1"
	SANITIZED_ROM_NAME="${ROM_NAME%.*}"
	echo "$SANITIZED_ROM_NAME"
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

configure_platform() {
	# ensure config and data directories and files exist
	mkdir -p "$FLYCAST_CONFIG_DIR" "$FLYCAST_DATA_DIR"
	cp -f "$PAK_DIR/config/emu.cfg" "${FLYCAST_CONFIG_DIR}emu.cfg"

	# migrate non-bios files are moved to the $FLYCAST_DATA_DIR
	cd "$FLYCAST_BIOS_DIR"
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

	find . -name '*.state' -print | xargs mv % "${FLYCAST_DATA_DIR}" || true

	cd "$PAK_DIR"
}

configure_controls() {
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

restore_save_states_for_game() {
	SANITIZED_ROM_NAME="$(get_sanitized_rom_name "$ROM_NAME")"
	mkdir -p "$FLYCAST_DATA_DIR" "$SHARED_USERDATA_PATH/DC-flycast"

	# check and copy platform-specific state files that already exist
	# this may happen if the game was saved on the device but we lost power before
	# we could restore them to the normal MinUI paths
	if [ -f "${FLYCAST_DATA_DIR}${SANITIZED_ROM_NAME}.state" ]; then
		cd "$FLYCAST_DATA_DIR"
		find . -name '*.state' -print | xargs mv % "$SHARED_USERDATA_PATH/DC-flycast/"
	fi

	# state files are the save states and should be restored from SHARED_USERDATA_PATH/DC-flycast/
	if [ -f "$SHARED_USERDATA_PATH/DC-flycast/$SANITIZED_ROM_NAME.state" ]; then
		cp -f "$SHARED_USERDATA_PATH/DC-flycast/$SANITIZED_ROM_NAME.state" "${FLYCAST_DATA_DIR}${SANITIZED_ROM_NAME}.state"
	fi

	touch /tmp/dc-saves-restored
}

configure_animations() {
	# update animations
	echo 1 >/sys/class/led_anim/effect_enable
	echo FFFFFF >/sys/class/led_anim/effect_rgb_hex_lr
	echo 1 >/sys/class/led_anim/effect_cycles_lr
	echo 1000 >/sys/class/led_anim/effect_duration_lr
	echo 1 >/sys/class/led_anim/effect_lr
}

show_message() {
	message="$1"
	seconds="$2"

	if [ -z "$seconds" ]; then
		seconds="forever"
	fi

	killall sdl2imgshow >/dev/null 2>&1 || true
	echo "$message" 1>&2
	if [ "$seconds" = "forever" ]; then
		sdl2imgshow \
			-i "$PAK_DIR/res/background.png" \
			-f "$PAK_DIR/res/fonts/BPreplayBold.otf" \
			-s 27 \
			-c "220,220,220" \
			-q \
			-t "$message" >/dev/null 2>&1 &
	else
		sdl2imgshow \
			-i "$PAK_DIR/res/background.png" \
			-f "$PAK_DIR/res/fonts/BPreplayBold.otf" \
			-s 27 \
			-c "220,220,220" \
			-q \
			-t "$message" >/dev/null 2>&1
		sleep "$seconds"
	fi
}

cleanup() {
	SANITIZED_ROM_NAME="$(get_sanitized_rom_name "$ROM_NAME")"

	rm -f /tmp/stay_awake
	killall sdl2imgshow >/dev/null 2>&1 || true

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
	if [ -f "${FLYCAST_DATA_DIR}${SANITIZED_ROM_NAME}.state" ]; then
		mv -f "${FLYCAST_DATA_DIR}${SANITIZED_ROM_NAME}.state" "$SHARED_USERDATA_PATH/DC-flycast/$SANITIZED_ROM_NAME.state"
	fi
}

main() {
	if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
		export DEVICE="brick"
		export PLATFORM="tg5040"
	fi

	if [ "$PLATFORM" != "tg5040" ]; then
		show_message "$PLATFORM is not a supported platform" 2
		exit 1
	fi

	trap cleanup INT TERM EXIT

	mkdir -p "$GAMESETTINGS_DIR"

	# migrate the old bios directory
	if [ -f "$BIOS_PATH/dc" ]; then
		mv "$BIOS_PATH/dc" "$BIOS_PATH/dreamcast"
		mv "$BIOS_PATH/dreamcast" "$BIOS_PATH/DC"
	fi

	configure_platform
	configure_controls
	configure_cpu
	restore_save_states_for_game
	configure_animations
	which trimui_inputd

	flycast --help || true
	flycast "$@"
}

main "$@"
