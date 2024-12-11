# slots_cte

A CTE for recursively generating slots for scheduled reports using in an in-app reporting feature.

This stored procedure solves the problem of converting a table of report rows with start times and periods into a table of individual slots for each period. Its main advantages are speed, accuracy, and resilience:

 - Speed is ensured by the bounded recursive nature of the procedure - only slots within the last X days are generated instead of creating them from the start date and then removing older slots with a WHERE clause (for a 10 year old report running every 10 minutes this would be over half a million slots!)
	 - This efficiency means that the procedure can be run very frequently by the server agent. This results in a responsive experience for the user as their 9am report slot will populate at the very latest at 9:01am
	 - The procedure will become slower the more reports there are to generate slots for, but its tight bounds  ensure scalability
 - Accuracy is maintained by pulling in information from other tables and using WHERE clauses to make sure that a user will never see a report which is older than 30 days, or in the future
	 - Both of these checks are applied using the user's local time and taking into account daylight savings
	 - Slots are not generated when another slot for that particular report already exists and would be more recent than the generated slot - this means that any changes the user makes to the period are only reflected going forwards from the change
 - Resilience is aided by the procedure being internal to the database and having no external dependences
	 - The insert check also means that the procedure can be run at any time and will not insert duplicate rows, but if the slots table happened to be wiped then the procedure would refill it from scratch without any intervention

###### Note: This was originally created and committed to a private repo at my work, so there is no git history available here
