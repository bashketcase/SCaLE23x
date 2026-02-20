#!/usr/bin/env bash

##############
# Credentials
##############

GCP_CLIENT_ID=""
GCP_CLIENT_SECRET=""
GCP_REFRESH_TOKEN=""
USER_ID="youremail%40email.com"
GCP_ACCESS_TOKEN=$(curl -sS -X POST https://oauth2.googleapis.com/token \
	-d "client_id=$GCP_CLIENT_ID" \
	-d "client_secret=$GCP_CLIENT_SECRET" \
	-d "refresh_token=$GCP_REFRESH_TOKEN" \
	-d "grant_type=refresh_token" | jq -r .access_token)
SPREADSHEET_ID=""

#############
# Definitions
#############

# Determine appropriate meal/snack category based on time of day
	# Breakfast 	= 7am - 9:30am
	# Lunch 		= 11:30am - 1:30pm
	# Dinner		= 5:30pm - 8:00pm
	# Snack			= any other time
meal_category() {
	TIME=$(date +%H%M)
	if [ "$TIME" -ge 0700 ] && [ "$TIME" -le 0930 ]; then
		CATEGORY="breakfast"
	elif [ "$TIME" -ge 1130 ] && [ "$TIME" -le 1330 ]; then
		CATEGORY="lunch"
	elif [ "$TIME" -ge 1730 ] && [ "$TIME" -le 2000 ]; then
		CATEGORY="dinner"
	else
		CATEGORY="snack"
	fi
}

# Get grocery list and all meals for specified category (based on time of day)
get_meals() {
	meal_category

	mapfile -t GROCERIES < <(curl -sS --request GET \
		"https://sheets.googleapis.com/v4/spreadsheets/$SPREADSHEET_ID/values/Groceries!A1:ZZ" \
		--header "Authorization: Bearer ${GCP_ACCESS_TOKEN}" \
		--header "Accept: application/json" | jq -r '.values[][0]')

	MEALS=$(curl -sS --request GET \
		"https://sheets.googleapis.com/v4/spreadsheets/$SPREADSHEET_ID/values/${CATEGORY}!A1:ZZ" \
		--header "Authorization: Bearer ${GCP_ACCESS_TOKEN}" \
		--header "Accept: application/json")
}

# Find nearby delivery options
find_delivery() {

	meal_category

	IP_LOCATION=$(curl -sS ipinfo.io | jq -r '[.city, .region, .country] | join(", ")')

	echo "This script uses your IP address to determine your geographical location for finding nearby restaurants."
	read -p "According to your IP address, your current location is ${IP_LOCATION}. Is that correct? (Y/N) " CONFIRMATION
	
	if [ ${CONFIRMATION} == 'Y' -o ${CONFIRMATION} == 'y' -o ${CONFIRMATION} == 'Yes' -o ${CONFIRMATION} == 'yes' -o ${CONFIRMATION} == 'YES' ]; then
		LOCATION=${IP_LOCATION}
	elif [ ${CONFIRMATION} == 'N' -o ${CONFIRMATION} == 'n' -o ${CONFIRMATION} == 'No' -o ${CONFIRMATION} == 'no' -o ${CONFIRMATION} == 'NO' ]; then
		read -p "Please enter your current location: " LOCATION
	else
		echo "Input not recognized; script will exit. Please re-run and be sure to enter Y/y/Yes/yes/YES or N/n/No/no/NO."
		exit
	fi

	RESULTS=$(curl -sS --request POST \
	--header "Authorization: Bearer ${GCP_ACCESS_TOKEN}" \
	--header "Accept: application/json" \
	--header "Content-Type: application/json" \
	--header "X-Goog-FieldMask: places.displayName,places.formattedAddress,places.regularOpeningHours,places.websiteUri" \
	--data "{
		\"textQuery\" : \"Delivery ${CATEGORY} food within 10 miles of ${LOCATION}\"
	}" \
	https://places.googleapis.com/v1/places:searchText)

	OPEN_RESTAURANTS=$(echo $RESULTS | jq '[.places[] | select(.regularOpeningHours.openNow == true) | {
	name: .displayName.text,
	website: .websiteUri,
	address: .formattedAddress
	}]')

	mapfile -t RESTAURANTS_ARRAY < <(echo "${OPEN_RESTAURANTS}" | jq -r '.[] | "\(.name)+\(.website);\(.address)"')

	if [ "${#RESTAURANTS_ARRAY[@]}" -le 0 ]; then
		echo "No open restaurants were found within 10 miles of your location. Time to forage in your fridge, comb through your cupboards, or get off your butt for groceries!"
	else
		NUM=$(( RANDOM % ${#RESTAURANTS_ARRAY[@]} ))
		RESTAURANT=${RESTAURANTS_ARRAY[$NUM]}
		TEMP="${RESTAURANT#*+}"
		echo "No time to decide on a restaurant?"
		echo "You should order from ${RESTAURANT%%+*}."
		echo "Website: ${TEMP%%;*}"
		echo "Address: ${RESTAURANT##*;}"
		echo " "
		echo "Have the brain space for more options?"

		for ITEM in "${RESTAURANTS_ARRAY[@]}"; do
			PLACEHOLDER="${ITEM#*+}"
			echo "Name: ${ITEM%%+*}"
			echo "Website: ${PLACEHOLDER%%;*}"
			echo "Address: ${ITEM##*;}"
			echo " "
		done
	fi
	
}

# Filter which meals are available based on your grocery list (assumes you are out of any ingredient that is on the grocery list)
available_meals() {
	AVAILABLE_MEALS=()

	for MEAL in "${MEALS_ARRAY[@]}"; do
		INGREDIENTS_STRING=${MEAL#*+}
    	IFS=',' read -ra INGREDIENTS <<< "$INGREDIENTS_STRING"
		for INGREDIENT in "${!INGREDIENTS[@]}"; do
			INGREDIENTS[$INGREDIENT]="${INGREDIENTS[$INGREDIENT]# }"
			INGREDIENTS[$INGREDIENT]="${INGREDIENTS[$INGREDIENT]% }"
		done

		for INGREDIENT in "${INGREDIENTS[@]}"; do
			for GROCERY in "${GROCERIES[@]}"; do
				if [ "$INGREDIENT" == "$GROCERY" ]; then
					continue 3
				fi
			done
		done

		AVAILABLE_MEALS+=("${MEAL%%+*}")
		NUM=$(( RANDOM % ${#AVAILABLE_MEALS[@]} ))
		echo "${AVAILABLE_MEALS[$NUM]}"
	done
}

# Decision flow that will be used if there are no energy options or if an energy boost isn't needed
decision_flow() {
	if [ "${#HOT_MEALS}" -ge 1 ] && [ "${#COLD_MEALS}" -ge 1 ]; then
		read -p "Would you prefer something hot or cold? (H/C) " TEMPERATURE
		if [ ${TEMPERATURE} == 'H' -o ${TEMPERATURE} == 'h' -o ${TEMPERATURE} == 'Hot' -o ${TEMPERATURE} == 'hot' -o ${TEMPERATURE} == 'HOT' ]; then
			echo "Hot! Great choice."
			# Hot and light/filling
			if [ "${#HOT_LIGHT_MEALS}" -ge 1 ] && [ "${#HOT_FILLING_MEALS}" -ge 1 ]; then
				read -p "Would you prefer something light or filling? (L/F) " FEEL
				if [ ${FEEL} == 'L' -o ${FEEL} == 'l' -o ${FEEL} == 'Light' -o ${FEEL} == 'light' -o ${FEEL} == 'LIGHT' ]; then
					NUM=$(( RANDOM % ${#HOT_LIGHT_MEALS[@]} ))
					SELECTION="${HOT_LIGHT_MEALS[$NUM]}"
					echo "For a hot, light ${CATEGORY}, you should eat: "
					echo "${SELECTION}"
				elif [ ${FEEL} == 'F' -o ${FEEL} == 'f' -o ${FEEL} == 'Filling' -o ${FEEL} == 'filling' -o ${FEEL} == 'FILLING' ]; then
					NUM=$(( RANDOM % ${#HOT_FILLING_MEALS[@]} ))
					SELECTION="${HOT_FILLING_MEALS[$NUM]}"
					echo "For a hot, filling ${CATEGORY}, you should eat: "
					echo "${SELECTION}"
				else
					NUM=$(( RANDOM % ${#HOT_MEALS[@]} ))
					SELECTION="${HOT_MEALS[$NUM]}"
					echo "Input not recognized. Script only accepts (L/l/Light/light/LIGHT) or (F/f/Filling/filling/FILLING)."
					echo "Just eat: "
					echo "${SELECTION}"
				fi
			else
				NUM=$(( RANDOM % ${#HOT_MEALS[@]} ))	
				SELECTION="${HOT_MEALS[$NUM]}"
				echo "For a hot ${CATEGORY}, you should eat: "
				echo "${SELECTION}"
			fi
		elif [ ${TEMPERATURE} == 'C' -o ${TEMPERATURE} == 'c' -o ${TEMPERATURE} == 'Cold' -o ${TEMPERATURE} == 'cold' -o ${TEMPERATURE} == 'COLD' ]; then
			echo "Cold! Great choice."
			# Cold and light/filling
			if [ "${#COLD_LIGHT_MEALS}" -ge 1 ] && [ "${#COLD_FILLING_MEALS}" -ge 1 ]; then
				read -p "Would you prefer something light or filling? (L/F) " FEEL
				if [ ${FEEL} == 'L' -o ${FEEL} == 'l' -o ${FEEL} == 'Light' -o ${FEEL} == 'light' -o ${FEEL} == 'LIGHT' ]; then
					NUM=$(( RANDOM % ${#COLD_LIGHT_MEALS[@]} ))
					SELECTION="${COLD_LIGHT_MEALS[$NUM]}"
					echo "For a cold, light ${CATEGORY}, you should eat: "
					echo "${SELECTION}"
				elif [ ${FEEL} == 'F' -o ${FEEL} == 'f' -o ${FEEL} == 'Filling' -o ${FEEL} == 'filling' -o ${FEEL} == 'FILLING' ]; then
					NUM=$(( RANDOM % ${#COLD_FILLING_MEALS[@]} ))
					SELECTION="${COLD_FILLING_MEALS[$NUM]}"
					echo "For a cold, filling ${CATEGORY}, you should eat: "
					echo "${SELECTION}"
				else
					NUM=$(( RANDOM % ${#ALL_AVAILABLE_MEALS[@]} ))
					SELECTION="${ALL_AVAILABLE_MEALS[$NUM]%%+*}"
					echo "Input not recognized. script only accepts (L/l/Light/light/LIGHT) or (F/f/Filling/filling/FILLING)."
					echo "Just eat: "
					echo "${SELECTION}"
				fi
			else
				NUM=$(( RANDOM % ${#COLD_MEALS[@]} ))
				SELECTION="${COLD_MEALS[$NUM]}"
				echo "For a cold ${CATEGORY}, you should eat: "
				echo "${SELECTION}"
			fi
		else
			NUM=$(( RANDOM % ${#ALL_AVAILABLE_MEALS[@]} ))
			SELECTION="${ALL_AVAILABLE_MEALS[$NUM]%%+*}"
			echo "Input not recognized. Script only accepts (H/h/Hot/hot/HOT) or (C/c/Cold/cold/COLD)."
			echo "Just eat: "
			echo "${SELECTION}"
		fi
	# Only hot or only cold meals are available - ask if user would prefer something light or filling
	else
		if [ "${#LIGHT_MEALS}" -ge 1 ] && [ "${#FILLING_MEALS}" -ge 1 ]; then
			read -p "Would you prefer something light or filling? (L/F) " FEEL
			if [ ${FEEL} == 'L' -o ${FEEL} == 'l' -o ${FEEL} == 'Light' -o ${FEEL} == 'light' -o ${FEEL} == 'LIGHT' ]; then
				NUM=$(( RANDOM % ${#LIGHT_MEALS[@]} ))
				SELECTION="${LIGHT_MEALS[$NUM]}"
				echo "For a light ${CATEGORY}, you should eat: "
				echo "${SELECTION}"
			elif [ ${FEEL} == 'F' -o ${FEEL} == 'f' -o ${FEEL} == 'Filling' -o ${FEEL} == 'filling' -o ${FEEL} == 'FILLING' ]; then
				NUM=$(( RANDOM % ${#FILLING_MEALS[@]} ))
				SELECTION="${FILLING_MEALS[$NUM]}"
				echo "For a filling ${CATEGORY}, you should eat: "
				echo "${SELECTION}"
			else
				NUM=$(( RANDOM % ${#ALL_AVAILABLE_MEALS[@]} ))
				SELECTION="${ALL_AVAILABLE_MEALS[$NUM]%%+*}"
				echo "Input not recognized. Script only accepts (L/l/Light/light/LIGHT) or (F/f/Filling/filling/FILLING)."
				echo "Just eat: "
				echo "${SELECTION}"
			fi
		# No decisions are availalbe so a random available meal will be chosen
		else
			NUM=$(( RANDOM % ${#ALL_AVAILABLE_MEALS[@]} ))
			SELECTION="${ALL_AVAILABLE_MEALS[$NUM]%%+*}"
			echo "You should eat: "
			echo "${SELECTION}"
		fi
	fi
}

# Overview of how the script works and arguments accepted
usage() {
	echo "Are you hungry? Don't know what you want to eat? This script has got your back- er, stomach."
	echo "Arguments accepted:"
	echo "'now'			= recommends some quick foods based on time of day"
	echo "'lazy'		= searches for the closest restaurants"
	echo "'roulette'	= recommends a random meal based on time of day"
	echo "no argument	= if no argument is provided it will prompt and use input to guide you to sustenance"
	echo "'usage'		= display this message"
}

########
# Calls
########

if [ "$#" -gt 0 ]; then
	if [ $1 == "usage" ]; then
		usage
	elif [ $1 == "now" ]; then
		get_meals
		QUICK_MEALS_OBJECT=$(echo ${MEALS} | jq -r '.values[] | select(.[2] > "0") | {name: .[0], ingredients: .[1]}')
		mapfile -t MEALS_ARRAY < <(echo "${QUICK_MEALS_OBJECT}" | jq -r 'select(.name != "Name") | "\(.name)+\(.ingredients)"')
		if [ "${#AVAILABLE_MEALS[@]}" -gt 0 ]; then
			echo "For a quick ${CATEGORY} you should eat:"
			available_meals
		else
			echo "Womp womp, you're out of quick ${CATEGORY} options. You need groceries, but until you can make a grocery run..."
			find_delivery
		fi
	elif [ $1 == "roulette" ]; then
		get_meals
		MEALS_OBJECT=$(echo ${MEALS} | jq -r '.values[] | {name: .[0], ingredients: .[1]}')
		mapfile -t MEALS_ARRAY < <(echo "${MEALS_OBJECT}" | jq -r 'select(.name != "Name") | "\(.name)+\(.ingredients)"')
		if [ "${#AVAILABLE_MEALS[@]}" -gt 0 ]; then
			echo "The lucky winning $CATEGORY is:"
			available_meals
		else
			echo "You REALLY need groceries, but until you can make a grocery run..."
			find_delivery
		fi
	elif [ $1 == "lazy" ]; then
		find_delivery
	else
		echo "Input not recognized. See usage for accepted arguments, or run without an argument to be guided to a food choice."
		usage
	fi
else
	get_meals
	ALL_MEALS_OBJECT=$(echo ${MEALS} | jq -r '.values[] | {name: .[0], ingredients: .[1], tags: (.[3] + .[4] + .[5])}')
	mapfile -t ALL_MEALS_ARRAY < <(echo "${ALL_MEALS_OBJECT}" | jq -r 'select(.name != "Name") | "\(.name)+\(.ingredients);\(.tags)"')

	# Filter available meals
	for MEAL in "${ALL_MEALS_ARRAY[@]}"; do
		TEMP="${MEAL#*+}"
		INGREDIENTS_STRING="${TEMP%%;*}"
	
    	IFS=',' read -ra INGREDIENTS <<< "$INGREDIENTS_STRING"
		for INGREDIENT in "${!INGREDIENTS[@]}"; do
			INGREDIENTS[$INGREDIENT]="${INGREDIENTS[$INGREDIENT]# }"
			INGREDIENTS[$INGREDIENT]="${INGREDIENTS[$INGREDIENT]% }"
		done

		for INGREDIENT in "${INGREDIENTS[@]}"; do
			for GROCERY in "${GROCERIES[@]}"; do
				if [ "$INGREDIENT" == "$GROCERY" ]; then
					continue 3
				fi
			done
		done

		ALL_AVAILABLE_MEALS+=("${MEAL%%+*}+${MEAL##*;}")
	done

	# If there are no available meals, find delivery
	if [ "${#ALL_AVAILABLE_MEALS[@]}" -le 0 ]; then
		echo "You're out of everything! It's delivery time..."
		find_delivery
	fi

	# Filter available meals by meal type: energy, temperature, and feel
	ENERGY_MEALS=()
	HOT_MEALS=()
	COLD_MEALS=()
	LIGHT_MEALS=()
	FILLING_MEALS=()
	HOT_LIGHT_MEALS=()
	HOT_FILLING_MEALS=()
	COLD_LIGHT_MEALS=()
	COLD_FILLING_MEALS=()
	ENERGY_HOT_LIGHT_MEALS=()
	ENERGY_HOT_FILLING_MEALS=()
	ENERGY_COLD_LIGHT_MEALS=()
	ENERGY_COLD_FILLING_MEALS=()

	for MEAL in "${ALL_AVAILABLE_MEALS[@]}"; do
		CODE="${MEAL##*+}"
		NAME="${MEAL%%+*}"

		if [ "${CODE}" == "1HL" ]; then
			ENERGY_MEALS+=("${NAME}")
			HOT_MEALS+=("${NAME}")
			LIGHT_MEALS+=("${NAME}")
			ENERGY_HOT_MEALS+=("${NAME}")
			ENERGY_LIGHT_MEALS+=("${NAME}")
			HOT_LIGHT_MEALS+=("${NAME}")
			ENERGY_HOT_LIGHT_MEALS+=("${NAME}")
		elif [ "${CODE}" == "0HL" ]; then
			HOT_MEALS+=("${NAME}")
			LIGHT_MEALS+=("${NAME}")
			HOT_LIGHT_MEALS+=("${NAME}")
		elif [ "${CODE}" == "1CL" ]; then
			ENERGY_MEALS+=("${NAME}")
			COLD_MEALS+=("${NAME}")
			LIGHT_MEALS+=("${NAME}")
			ENERGY_COLD_MEALS+=("${NAME}")
			ENERGY_LIGHT_MEALS+=("${NAME}")
			COLD_LIGHT_MEALS+=("${NAME}")
			ENERGY_COLD_LIGHT_MEALS+=("${NAME}")
		elif [ "${CODE}" == "0CL" ]; then
			COLD_MEALS+=("${NAME}")
			LIGHT_MEALS+=("${NAME}")
			COLD_LIGHT_MEALS+=("${NAME}")
		elif [ "${CODE}" == "1HF" ]; then
			ENERGY_MEALS+=("${NAME}")
			HOT_MEALS+=("${NAME}")
			FILLING_MEALS+=("${NAME}")
			ENERGY_HOT_MEALS+=("${NAME}")
			ENERGY_FILLING_MEALS+=("${NAME}")
			HOT_FILLING_MEALS+=("${NAME}")
			ENERGY_HOT_FILLING_MEALS+=("${NAME}")
		elif [ "${CODE}" == "0HF" ]; then
			HOT_MEALS+=("${NAME}")
			FILLING_MEALS+=("${NAME}")
			HOT_FILLING_MEALS+=("${NAME}")
		elif [ "${CODE}" == "1CF" ]; then
			ENERGY_MEALS+=("${NAME}")
			COLD_MEALS+=("${NAME}")
			FILLING_MEALS+=("${NAME}")
			ENERGY_COLD_MEALS+=("${NAME}")
			ENERGY_FILLING_MEALS+=("${NAME}")
			COLD_FILLING_MEALS+=("${NAME}")
			ENERGY_COLD_FILLING_MEALS+=("${NAME}")
		elif [ "${CODE}" == "0CF" ]; then
			COLD_MEALS+=("${NAME}")
			FILLING_MEALS+=("${NAME}")
			COLD_FILLING_MEALS+=("${NAME}")
		fi
	done

	# Only ask for preference if there is at least one meal available for each option.
	if [ "${#ENERGY_MEALS[@]}" -ge 1 ]; then
		read -p "Do you need an energy boost? (Y/N) " ENERGY
		if [ ${ENERGY} == 'Y' -o ${ENERGY} == 'y' -o ${ENERGY} == 'Yes' -o ${ENERGY} == 'yes' -o ${ENERGY} == 'YES' ]; then
			echo "Energy boost it is!"
			if [ "${#ENERGY_HOT_MEALS}" -ge 1 ] && [ "${#ENERGY_COLD_MEALS}" -ge 1 ]; then
				read -p "Would you prefer something hot or cold? (H/C) " TEMPERATURE
				if [ ${TEMPERATURE} == 'H' -o ${TEMPERATURE} == 'h' -o ${TEMPERATURE} == 'Hot' -o ${TEMPERATURE} == 'hot' -o ${TEMPERATURE} == 'HOT' ]; then
					echo "Hot! Great choice."
					if [ "${#ENERGY_HOT_LIGHT_MEALS}" -ge 1 ] && [ "${#ENERGY_HOT_FILLING_MEALS}" -ge 1 ]; then
						read -p "Would you prefer something light or filling? (L/F) " FEEL
						if [ ${FEEL} == 'L' -o ${FEEL} == 'l' -o ${FEEL} == 'Light' -o ${FEEL} == 'light' -o ${FEEL} == 'LIGHT' ]; then
							NUM=$(( RANDOM % ${#ENERGY_HOT_LIGHT_MEALS[@]} ))
							SELECTION="${ENERGY_HOT_LIGHT_MEALS[$NUM]}"
							echo "For a hot, light ${CATEGORY} that will give you energy, you should eat: "
							echo "${SELECTION}"
						elif [ ${FEEL} == 'F' -o ${FEEL} == 'f' -o ${FEEL} == 'Filling' -o ${FEEL} == 'filling' -o ${FEEL} == 'FILLING' ]; then
							NUM=$(( RANDOM % ${#ENERGY_HOT_FILLING_MEALS[@]} ))
							SELECTION="${ENERGY_HOT_FILLING_MEALS[$NUM]}"
							echo "For a hot, filling ${CATEGORY} that will give you energy, you should eat: "
							echo "${SELECTION}"
						else
							NUM=$(( RANDOM % ${#ENERGY_HOT_MEALS[@]} ))
							SELECTION="${ENERGY_HOT_MEALS[$NUM]}"
							echo "Input not recognized. Script only accepts (L/l/Light/light/LIGHT) or (F/f/Filling/filling/FILLING)."
							echo "Just eat: "
							echo "${SELECTION}"
						fi
					else
						NUM=$(( RANDOM % ${#ENERGY_HOT_MEALS[@]} ))
						SELECTION="${ENERGY_HOT_MEALS[$NUM]}"
						echo "For a hot {$CATEGORY} that will give you energy, you should eat: "
						echo "${SELECTION}"
					fi
				elif [ ${TEMPERATURE} == 'C' -o ${TEMPERATURE} == 'c' -o ${TEMPERATURE} == 'Cold' -o ${TEMPERATURE} == 'cold' -o ${TEMPERATURE} == 'COLD' ]; then
					echo "Cold! Great choice."
					if [ "${#ENERGY_COLD_LIGHT_MEALS}" -ge 1 ] && [ "${#ENERGY_COLD_FILLING_MEALS}" -ge 1 ]; then
						read -p "Would you prefer something light or filling? (L/F) " FEEL
						if [ ${FEEL} == 'L' -o ${FEEL} == 'l' -o ${FEEL} == 'Light' -o ${FEEL} == 'light' -o ${FEEL} == 'LIGHT' ]; then
							NUM=$(( RANDOM % ${#ENERGY_COLD_LIGHT_MEALS[@]} ))
							SELECTION="${ENERGY_COLD_LIGHT_MEALS[$NUM]}"
							echo "For a cold, light ${CATEGORY} that will give you energy, you should eat: "
							echo "${SELECTION}"
						elif [ ${FEEL} == 'F' -o ${FEEL} == 'f' -o ${FEEL} == 'Filling' -o ${FEEL} == 'filling' -o ${FEEL} == 'FILLING' ]; then
							NUM=$(( RANDOM % ${#ENERGY_COLD_FILLING_MEALS[@]} ))
							SELECTION="${ENERGY_COLD_FILLING_MEALS[$NUM]}"
							echo "For a cold, filling ${CATEGORY} that will give you energy, you should eat: "
							echo "${SELECTION}"
						else
							NUM=$(( RANDOM % ${#ENERGY_COLD_MEALS[@]} ))
							SELECTION="${ENERGY_COLD_MEALS[$NUM]}"
							echo "Input not recognized. Script only accepts (L/l/Light/light/LIGHT) or (F/f/Filling/filling/FILLING)."
							echo "Just eat: "
							echo "${SELECTION}"
						fi
					else
						NUM=$(( RANDOM % ${#ENERGY_COLD_MEALS[@]} ))
						SELECTION="${ENERGY_COLD_MEALS[$NUM]}"
						echo "For a cold {$CATEGORY} that will give you energy, you should eat: "
						echo "${SELECTION}"
					fi
				else
					NUM=$(( RANDOM % ${#ENERGY_MEALS[@]} ))
					SELECTION="${ENERGY_MEALS[$NUM]}"
					echo "Input not recognized. Script only accepts (H/h/Hot/hot/HOT) or (C/c/Cold/cold/COLD)."
					echo "Just eat: "
					echo "${SELECTION}"
				fi
			else
				if [ "${ENERGY_LIGHT_MEALS}" -ge 1 ] && [ "${ENERGY_FILLING_MEALS}" -ge 1 ]; then
					read -p "Would you prefer something light or filling? (L/F) " FEEL
					if [ ${FEEL} == 'L' -o ${FEEL} == 'l' -o ${FEEL} == 'Light' -o ${FEEL} == 'light' -o ${FEEL} == 'LIGHT' ]; then
						NUM=$(( RANDOM % ${#ENERGY_LIGHT_MEALS[@]} ))
						SELECTION="${ENERGY_LIGHT_MEALS[$NUM]}"
						echo "For a light ${CATEGORY} that will give you energy, you should eat: "
						echo "${SELECTION}"
					elif [ ${FEEL} == 'F' -o ${FEEL} == 'f' -o ${FEEL} == 'Filling' -o ${FEEL} == 'filling' -o ${FEEL} == 'FILLING' ]; then
						NUM=$(( RANDOM % ${#ENERGY_FILLING_MEALS[@]} ))
						SELECTION="${ENERGY_FILLING_MEALS[$NUM]}"
						echo "For a filling ${CATEGORY} that will give you energy, you should eat: "
						echo "${SELECTION}"
					else
						NUM=$(( RANDOM % ${#ENERGY_MEALS[@]} ))
						SELECTION="${ENERGY_MEALS[$NUM]}"
						echo "Input not recognized. Script only accepts (L/l/Light/light/LIGHT) or (F/f/Filling/filling/FILLING)."
						echo "Just eat: "
						echo "${SELECTION}"
					fi
				else
					NUM=$(( RANDOM % ${#ENERGY_MEALS[@]} ))
					SELECTION="${ENERGY_MEALS[$NUM]}"
					echo "For a ${CATEGORY} that will give you some energy, you should eat: "
					echo "${SELECTION}"
				fi
			fi
		elif [ ${ENERGY} == 'N' -o ${ENERGY} == 'n' -o ${ENERGY} == 'No' -o ${ENERGY} == 'no' -o ${ENERGY} == 'NO' ]; then
			decision_flow
		else
			NUM=$(( RANDOM % ${#ALL_AVAILABLE_MEALS[@]} ))
			SELECTION="${ALL_AVAILABLE_MEALS[$NUM]%%+*}"
			echo "Input not recognized. Script only accepts (Y/y/Yes/yes/YES) or (N/n/No/no/NO)."
			echo "Just eat: "
			echo "${SELECTION}"
		fi
	# No energy meals are available - progress to hot/cold choice if available
	else
		decision_flow
	fi	
fi