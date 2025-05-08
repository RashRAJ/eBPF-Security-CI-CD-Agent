# Secret Detection Policy
package kntrl.network["detect_secrets"]

import rego.v1

# Detect potential secrets in URLs
policy := "block" if {
  url := input.url
  
  # Look for common secret patterns
  secret_patterns := [
    "password=",
    "api_key=",
    "token=",
    "secret=",
    "auth=",
    "key=",
    "client_secret="
  ]
  
  pattern := secret_patterns[_]
  contains(url, pattern)
}