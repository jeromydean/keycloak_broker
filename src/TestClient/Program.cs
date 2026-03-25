using System.Collections.Generic;
using System.Net.Http.Headers;
using Microsoft.Identity.Client;

namespace TestClient
{
  /// <summary>
  /// POC: sign in to the <strong>cloud</strong> Keycloak realm (broker). Pass a tenant / IdP hint on the
  /// command line (e.g. <c>onprem_1</c> → broker alias <c>onprem-1</c>) so Keycloak skips the IdP chooser
  /// via <c>kc_idp_hint</c>. Then sign in with the matching on-prem user (e.g. <c>onprem1_user</c>).
  /// </summary>
  internal static class Program
  {
    /// <summary>Cloud realm (broker IdPs: onprem-1 / onprem-2).</summary>
    private const string OidcAuthority = "https://localhost:8080/realms/cloud";

    /// <summary>Public client on cloud realm from keycloak-setup.ps1 (redirects include loopback).</summary>
    private const string ClientId = "test-client";

    private const string RedirectUri = "http://localhost";

    /// <summary>CloudAPI POC URL (see CloudAPI launchSettings / appsettings).</summary>
    private const string CloudApiBase = "http://localhost:5300";

    private static readonly string[] Scopes = { "openid", "profile", "email" };

    /// <summary>
    /// Maps a friendly tenant name (e.g. <c>onprem_1</c>) to the Keycloak broker IdP <b>alias</b>
    /// (<c>onprem-1</c>). If the value already contains <c>-</c>, it is used as-is.
    /// </summary>
    private static string ToBrokerIdpAlias(string tenantOrAlias)
    {
      string trimmed = tenantOrAlias.Trim();
      if (trimmed.Contains('-'))
      {
        return trimmed;
      }

      return trimmed.Replace('_', '-');
    }

    private static async Task Main(string[] args)
    {
      args = new string[] { "onprem_1" };
      Console.WriteLine("MSAL + Keycloak cloud realm (IdP broker -> on-prem)");
      Console.WriteLine($"  Authority:     {OidcAuthority}");
      Console.WriteLine($"  Client id:     {ClientId}");
      if (args.Length > 0 && !string.IsNullOrWhiteSpace(args[0]))
      {
        string idpAlias = ToBrokerIdpAlias(args[0]);
        Console.WriteLine($"  Broker IdP:    {idpAlias}  (sent as kc_idp_hint — skips IdP chooser when allowed)");
      }
      else
      {
        Console.WriteLine("  Broker IdP:    (not set — Keycloak shows IdP chooser). Use: dotnet run -- onprem_1  or  onprem-2");
      }

      Console.WriteLine($"  Then calling:  {CloudApiBase}/api/whoami");
      Console.WriteLine();

      IPublicClientApplication app = PublicClientApplicationBuilder
          .Create(ClientId)
          .WithExperimentalFeatures(true)
          .WithOidcAuthority(OidcAuthority)
          .WithRedirectUri(RedirectUri)
          .Build();

      try
      {
        AcquireTokenInteractiveParameterBuilder interactive = app
            .AcquireTokenInteractive(Scopes)
            .WithPrompt(Prompt.SelectAccount);

        if (args.Length > 0 && !string.IsNullOrWhiteSpace(args[0]))
        {
          string idpAlias = ToBrokerIdpAlias(args[0]);
          Dictionary<string, (string Value, bool IncludeInCacheKey)> brokerHint = new(1)
          {
            ["kc_idp_hint"] = (idpAlias, true),
          };
          interactive = interactive.WithExtraQueryParameters(brokerHint);
        }

        AuthenticationResult result = await interactive.ExecuteAsync().ConfigureAwait(false);

        Console.WriteLine("Signed in (token issued by cloud realm).");
        Console.WriteLine($"  Username (from result): {result.Account?.Username ?? "(none)"}");
        Console.WriteLine($"  Expires (UTC): {result.ExpiresOn:O}");
        Console.WriteLine();

        using HttpClient http = new HttpClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", result.AccessToken);
        using HttpResponseMessage apiResponse = await http.GetAsync(new Uri($"{CloudApiBase}/api/whoami"))
            .ConfigureAwait(false);
        string apiBody = await apiResponse.Content.ReadAsStringAsync().ConfigureAwait(false);
        if (apiResponse.IsSuccessStatusCode)
        {
          Console.WriteLine($"{CloudApiBase}/api/whoami response:");
          Console.WriteLine(apiBody);
        }
        else
        {
          Console.Error.WriteLine($"API error {(int)apiResponse.StatusCode} {apiResponse.ReasonPhrase}");
          Console.Error.WriteLine(apiBody);
          Console.Error.WriteLine();
          Console.Error.WriteLine("Start CloudAPI from src/CloudAPI (profile http -> port 5300) and ensure JWT Authority matches cloud realm.");
          Environment.ExitCode = 1;
        }
      }
      catch (MsalException ex)
      {
        Console.Error.WriteLine($"MSAL error: {ex.ErrorCode} - {ex.Message}");
        Environment.ExitCode = 1;
      }
    }
  }
}
