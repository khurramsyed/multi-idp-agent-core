// Brokers read claims for their own agency's customers.
// Cognito access-token claims arrive in Verified Permissions as context.token.
permit (
  principal,
  action == ClaimsAssist::Action::"ReadClaim",
  resource is ClaimsAssist::Claim
)
when {
  context.token.population == "broker" &&
  context.token.agency_id != "" &&
  resource.agencyId == context.token.agency_id
};
