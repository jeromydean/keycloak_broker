using Microsoft.Identity.Client;

namespace TestClient
{
  /// <summary>
  /// POC: sign in to Keycloak onprem_1 via MSAL generic OIDC (PublicClientApplicationBuilder.WithOidcAuthority).
  /// Run keycloak-setup.ps1 from the repo root first; sign in as e.g. onprem1_user.
  /// </summary>
  internal static class Program
  {
    /// <summary>Issuer base URL (no trailing slash). MSAL loads discovery from {Authority}/.well-known/openid-configuration.</summary>
    private const string OidcAuthority = "http://localhost:8181/realms/onprem";

    /// <summary>Public client created by keycloak-setup.ps1 in realm <c>onprem</c>.</summary>
    private const string ClientId = "msal-onprem";

    /// <summary>Must match a valid redirect URI on the Keycloak client (MSAL default for .NET + system browser).</summary>
    private const string RedirectUri = "http://localhost";

    private static readonly string[] Scopes = { "openid", "profile", "email" };

    private static async Task Main(string[] args)
    {
      Console.WriteLine("MSAL + Keycloak (onprem_1 / realm onprem)");
      Console.WriteLine($"  Authority: {OidcAuthority}");
      Console.WriteLine($"  Client id: {ClientId}");
      Console.WriteLine("Opening system browser for sign-in...");
      Console.WriteLine();

      IPublicClientApplication app = PublicClientApplicationBuilder
          .Create(ClientId)
          .WithExperimentalFeatures(true)
          .WithOidcAuthority(OidcAuthority)
          .WithRedirectUri(RedirectUri)
          .Build();

      try
      {
        AuthenticationResult result = await app
            .AcquireTokenInteractive(Scopes)
            .WithPrompt(Prompt.SelectAccount)
            .ExecuteAsync()
            .ConfigureAwait(false);

        Console.WriteLine("Signed in.");
        Console.WriteLine($"  Username (from result): {result.Account?.Username ?? "(none)"}");
        Console.WriteLine($"  Expires (UTC): {result.ExpiresOn:O}");
        Console.WriteLine();
        Console.WriteLine("Access token (truncated):");
        string access = result.AccessToken;
        int show = Math.Min(80, access.Length);
        Console.WriteLine($"  {access.AsSpan(0, show)}...");
      }
      catch (MsalException ex)
      {
        Console.Error.WriteLine($"MSAL error: {ex.ErrorCode} - {ex.Message}");
        Environment.ExitCode = 1;
      }
    }
  }
}
