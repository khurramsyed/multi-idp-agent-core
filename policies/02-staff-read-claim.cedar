// Adjusters read claims in their own region.
permit (
  principal,
  action == ClaimsAssist::Action::"ReadClaim",
  resource is ClaimsAssist::Claim
)
when {
  context.token.population == "staff" &&
  ["claims-adjuster", "claims-senior-adjuster"].contains(context.token.role) &&
  resource.region == context.token.region
};
