#!/bin/bash

##############
# Credentials
##############

GCP_CLIENT_ID=""
GCP_CLIENT_SECRET=""
GCP_REFRESH_TOKEN=""
JIRA_API_TOKEN=""
JIRA_AUTH_STRING=""
DD_API_KEY=""
DD_APP_KEY=""
NEWSMESH_API_KEY=""
# Note: AWS credentials will be needed for that portion of the script to work. They are not included here due to our company login flow.

#############
# Definitions
#############

# Print meeting schedule from Google calendar, then list only the emails I actually need to care about
get_gsuite() {
	echo " "
	echo "####################"
	echo "# Today's Meetings #"
	echo "####################"	
	echo " "

	GCP_ACCESS_TOKEN=$(curl -sS -X POST https://oauth2.googleapis.com/token \
	-d "client_id=$GCP_CLIENT_ID" \
	-d "client_secret=$GCP_CLIENT_SECRET" \
	-d "refresh_token=$GCP_REFRESH_TOKEN" \
	-d "grant_type=refresh_token" | jq -r .access_token)

	USER_ID="youremail%40company.com"
	TODAY=$(date +%Y-%m-%d)
	TOMORROW=$(date -v+1d +%Y-%m-%d)
	YESTERDAY=$(date -v-2d +%Y-%m-%d)
	OFFSET=$(date +%z)
	OFFSET="${OFFSET%??}:${OFFSET#???}"
	DAY_START="${TODAY}T00:00:00${OFFSET}"
	DAY_END="${TOMORROW}T00:00:00${OFFSET}"

	curl -sS -H "Authorization: Bearer $GCP_ACCESS_TOKEN" \
	"https://www.googleapis.com/calendar/v3/calendars/${USER_ID}/events?singleEvents=true&orderBy=startTime&timeMin=${DAY_START}&timeMax=${DAY_END}" \
	| jq -r '.items[] |
  	"\(.summary)
	Start: \(.start.dateTime | split("T")[1] | split("-")[0])
	End: \(.end.dateTime | split("T")[1] | split("-")[0])
	URI: \((.conferenceData.entryPoints[]? | select(.entryPointType=="video") | .uri) // "N/A")
	---"'

	echo " "
	echo "####################"
	echo "# Important Emails #"
	echo "####################"	
	echo " "

	EMAIL_LIST=$(curl -sS -X GET -H "Authorization: Bearer ${GCP_ACCESS_TOKEN}" \
  	"https://gmail.googleapis.com/gmail/v1/users/${USER_ID}/messages?q=is%3Aunread+newer_than%3A2d+%28from%3A%22Justin-Nicholas+Toyama%22+OR+from%3A%22Greg+Nolan%22+OR+from%3Aopsgenie+OR+subject%3A%22SSL+Certificate%22+OR+subject%3ADatadog%29")
	EMAIL_IDS=($(echo ${EMAIL_LIST} | jq -r .'messages[].id'))
	
	echo "You have ${#EMAIL_IDS[@]} unread emails that you have to care about."

	if [ ${#EMAIL_IDS[@]} -gt 0 ]; then
		for ID in ${EMAIL_IDS[@]}; 
		do
			EMAIL=$(curl -sS -X GET -H "Authorization: Bearer ${GCP_ACCESS_TOKEN}" \
			"https://gmail.googleapis.com/gmail/v1/users/${USER_ID}/messages/${ID}")
			DATE_RECEIVED=$(echo $EMAIL | jq -r '.payload.headers[] | select(.name == "Date") | .value')
			SENDER=$(echo $EMAIL | jq -r '.payload.headers[] | select(.name == "Sender") | .value')
			SUBJECT=$(echo $EMAIL | jq -r '.payload.headers[] | select(.name == "Subject") | .value')
			
			echo " "
			echo "Date: ${DATE_RECEIVED}"
			echo "Sender: ${SENDER}"
			echo "Subject: ${SUBJECT}"
		done
	fi
	
}

# List Jira tickets in progress
get_tickets() {
	echo " "
	echo "#######################"
	echo "# Tickets in Progress #"
	echo "#######################"
	echo " "

	EMAIL="youremail@email.com"
	API_TOKEN="$JIRA_API_TOKEN"

	curl -sS -u "${EMAIL}:${API_TOKEN}" \
	-H "Accept: application/json" \
	-G "https://company.atlassian.net/rest/api/3/search/jql" \
	--data-urlencode 'jql=project = SO AND assignee = 5dd6f625c7ac480ee56762c7 AND issuetype = Task AND status = Development' \
	--data-urlencode 'maxResults=50' \
	--data-urlencode 'fields=summary,status,assignee,key' \
	| jq -r '.issues[] | "Ticket no.: \(.key) | Title: \(.fields.summary)"'

}

# Summary of security signals from the past 24 hours, or past 3 days if it's Monday
datadog_signals() {
	echo " "
	echo "############################"
	echo "# DATADOG SECURITY SIGNALS #"
	echo "############################"
	echo " "

	TODAY=$(date +%A)

	FROM_THREE=$(date -u -v-3d +"%Y-%m-%dT%H:%M:%SZ")
	FROM_ONE=$(date -u -v-1d +"%Y-%m-%dT%H:%M:%SZ")
	TO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	if [ "$TODAY" = "Monday" ]; then
		echo "Medium-severity security signals in the last 3 days: "
		START_HERE=${FROM_THREE}
	else
		echo "Medium-severity security signals in the last 1 day: "
		START_HERE=${FROM_ONE}
	fi

	DD_SIGNALS=$(curl -s -G 'https://api.datadoghq.com/api/v2/security_monitoring/signals' \
	-H 'Accept: application/json' \
	-H "DD-API-KEY: ${DD_API_KEY}" \
	-H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
	--data-urlencode "filter[query]=status:medium" \
	--data-urlencode "filter[from]=$START_HERE" \
	--data-urlencode "filter[to]=$TO" | jq -r '.data')

	if [ "$DD_SIGNALS" == "[]" ]; then
		echo "None! Woo!"
	else
		echo "$DD_SIGNALS" | jq -r '
		def get_actor:
			# Actor label differs based on source integration
			.attributes.attributes.github.actor // 
			.attributes.attributes.cloudflare.actor_email // 
			.attributes.attributes.aws.userIdentity.principalId // 
			.attributes.attributes.gcp.principal_email //
			.attributes.attributes.okta.actor.alternateId //
			.attributes.attributes.user.name // 
			.attributes.attributes.user.email // 
			"unknown";
		
		.[] | {
			Timestamp: .attributes.timestamp,
			Source: (.attributes.service[0] // "unknown"),
			Title: .attributes.attributes.title,
			Actor: get_actor
		}'
	fi
}

# High-level overview of resource usage per DB cluster for the last 12 hours
db_status() {
	echo " "
	echo "#########################################"
	echo "# Database Resource Usage Last 12 Hours #"
	echo "#########################################"
	echo " "

	DB_IDS=("master-r5-24x" "tenant-0001-company-prod-1" "tenant-0002-company-prod-1" "tenant-0003-company-prod-1" "tenant-0004-company-prod-1" "tenant-0005-company-prod-1" "tenant-0006-company-prod-1" "tenant-0007-company-prod-1" "tenant-0008-company-prod-1" "tenant-0009-company-prod-1" "tenant-0010-company-prod-1" "tenant-0011-company-prod-1" "tenant-0012-company-prod-1" "tenant-0013-company-prod-1" "tenant-0014-company-prod-1" "tenant-0015-company-prod-1" "tenant-0016-company-prod-1" "tenant-0017-company-prod-1" "tenant-0017-company-prod-1")

	for DB in ${DB_IDS[@]}; 
	do
		avg_cpu_usage=$(aws cloudwatch get-metric-statistics \
		--namespace AWS/RDS \
		--metric-name CPUUtilization \
		--dimensions Name=DBInstanceIdentifier,Value=$DB \
		--start-time $(date -u -v-12H +"%Y-%m-%dT%H:%M:%SZ") \
		--end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		--period 3600 \
		--statistics Average \
		--output json | jq '[
			.Datapoints[] | .Average
		] | add / length')

		max_cpu_usage=$(aws cloudwatch get-metric-statistics \
		--namespace AWS/RDS \
		--metric-name CPUUtilization \
		--dimensions Name=DBInstanceIdentifier,Value=$DB \
		--start-time $(date -u -v-12H +"%Y-%m-%dT%H:%M:%SZ") \
		--end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		--period 3600 \
		--statistics Maximum \
		--output json | jq '[
			.Datapoints[] | .Maximum
		] | max')

		avg_freeable_memory=$(aws cloudwatch get-metric-statistics \
		--namespace AWS/RDS \
		--metric-name FreeableMemory \
		--dimensions Name=DBInstanceIdentifier,Value=$DB \
		--start-time $(date -u -v-12H +"%Y-%m-%dT%H:%M:%SZ") \
		--end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		--period 300 \
		--statistics Average \
		--output json | jq '[
			.Datapoints[] | .Average
		] | add / length')

		min_freeable_memory=$(aws cloudwatch get-metric-statistics \
		--namespace AWS/RDS \
		--metric-name FreeableMemory \
		--dimensions Name=DBInstanceIdentifier,Value=$DB \
		--start-time $(date -u -v-12H +"%Y-%m-%dT%H:%M:%SZ") \
		--end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		--period 300 \
		--statistics Minimum \
		--output json | jq '[
			.Datapoints[] | .Minimum
		] | min')

		avg_disk_queue_depth=$(aws cloudwatch get-metric-statistics \
		--namespace AWS/RDS \
		--metric-name DiskQueueDepth \
		--dimensions Name=DBInstanceIdentifier,Value=$DB \
		--start-time $(date -u -v-12H +"%Y-%m-%dT%H:%M:%SZ") \
		--end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		--period 300 \
		--statistics Average \
		--output json | jq '[
			.Datapoints[] | .Average
		] | add / length')

		max_disk_queue_depth=$(aws cloudwatch get-metric-statistics \
		--namespace AWS/RDS \
		--metric-name DiskQueueDepth \
		--dimensions Name=DBInstanceIdentifier,Value=$DB \
		--start-time $(date -u -v-12H +"%Y-%m-%dT%H:%M:%SZ") \
		--end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		--period 300 \
		--statistics Maximum \
		--output json | jq '[
			.Datapoints[] | .Maximum
		] | max')

		formatted_avg_cpu_usage=$(printf "%.2f" "$avg_cpu_usage")
		formatted_max_cpu_usage=$(printf "%.2f" "$max_cpu_usage")
		formatted_avg_freeable_memory=$(printf "%.2f" "$avg_freeable_memory")
		formatted_min_freeable_memory=$(printf "%.2f" "$min_freeable_memory")
		formatted_avg_disk_queue_depth=$(printf "%.2f" "$avg_disk_queue_depth")
		formatted_max_disk_queue_depth=$(printf "%.2f" "$max_disk_queue_depth")

		echo "DB: $DB"
		echo "Average CPU utilization: ${formatted_avg_cpu_usage}%"
		echo "Maximum CPU utilization: ${formatted_max_cpu_usage}%"
		echo "Average Freeable Memory: ${formatted_avg_freeable_memory} bytes"
		echo "Minimum Freeable Memory: ${formatted_min_freeable_memory} bytes"
		echo "Average Disk Queue Depth: ${formatted_avg_disk_queue_depth} outstanding I/Os"
		echo "Maximum Disk Queue Depth: ${formatted_max_disk_queue_depth} outstanding I/Os"
		echo " "

	done
}

# Finds one piece of positive news from the last 24 hours
good_news() {
	echo " "
	echo "#############"
	echo "# Good News #"
	echo "#############"
	echo " "

	NEWS_RESULTS=$(curl -sS "https://api.newsmesh.co/v1/search?apiKey=${NEWSMESH_API_KEY}&category=sports,technology,science&q=uplifting+OR+joyful&source=BBC&limit=3")
	echo ${NEWS_RESULTS} | jq -r '
  		.data[] |
  		"Title: \(.title)\nDescription: \(.description)\nRead More: \(.link)\n"
		'
}

# Reminder to be grateful
gratitude() {
	THINGS_TO_BE_GRATEFUL_FOR=("for the existence of coffee" "that you get to do what you love for a living" "for weighted blankets and snacks" "for music and the ability to sing out loud in your car without anyone hearing you" "there are videos of cute animals doing silly things on YouTube" "you've lived to eat another bowl of pasta" "that you can get your favorite salad at Trader Joe's" "for technology that makes your best friends only a text away" "that you get to volunteer with horses" "for noise cancelling technology" "for margaritas with Tajin rims" "that you live somewhere it doesn't snow" "that you have lots of cuddly sweaters for when it is chilly")
	NUM=$((RANDOM % 14))

	echo "Today, take a moment to be grateful ${THINGS_TO_BE_GRATEFUL_FOR[${NUM}]}."
}

#######
# Calls
#######

echo "Good morning! Preparing your daily digest..."

get_gsuite
get_tickets
datadog_signals
db_status
good_news
gratitude

echo "...and that's it! Don't forget to drink water, move your body, take your meds, and tell the people you love that you love them!"