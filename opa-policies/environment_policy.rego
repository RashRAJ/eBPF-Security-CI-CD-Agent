#Environment-specific Policy
package kntrl.network["environment_policy"]

import rego.v1

# Different rules for different environments
policy if {
  # Get environment from Kubernetes labels or env vars
  env := input.environment
  
  # Production environment - strict rules
  env == "production"
  input.domains[_] in data.production_allowed_domains
}

policy if {
  # Development environment - more permissive
  env == "development"
  not input.domains[_] in data.explicitly_blocked_domains
}