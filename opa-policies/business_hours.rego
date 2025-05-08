# Time-based Access Policy
package kntrl.network["business_hours"]

import rego.v1

# Only allow external access during business hours
policy if {
  current_hour := time.clock([time.now_ns(), "UTC"])[0]
  current_hour >= 8
  current_hour <= 18
  
  # Check if it's a weekday
  weekday := time.weekday(time.now_ns())
  weekday != "Saturday"
  weekday != "Sunday"
}