using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Configuration;

namespace CloudAPI
{
  internal static class Program
  {
    private sealed record ClaimEntry(string Type, string Value);

    private static void Main(string[] args)
    {
      WebApplicationBuilder builder = WebApplication.CreateBuilder(args);

      IConfigurationSection jwtSection = builder.Configuration.GetSection("Authentication:JwtBearer");
      string authority = jwtSection["Authority"]
          ?? throw new InvalidOperationException("Configuration 'Authentication:JwtBearer:Authority' is required (Keycloak realm URL, e.g. http://localhost:8080/realms/master).");
      string? audience = jwtSection["Audience"];
      bool requireHttpsMetadata = jwtSection.GetValue("RequireHttpsMetadata", false);

      builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
          .AddJwtBearer(options =>
          {
            options.Authority = authority;
            options.RequireHttpsMetadata = requireHttpsMetadata;

            string? metadataAddress = jwtSection["MetadataAddress"];
            if (!string.IsNullOrWhiteSpace(metadataAddress))
            {
              options.MetadataAddress = metadataAddress;
            }

            if (!string.IsNullOrWhiteSpace(audience))
            {
              options.Audience = audience;
            }
            else
            {
              options.TokenValidationParameters.ValidateAudience = false;
            }
          });

      builder.Services.AddAuthorization();

      WebApplication app = builder.Build();

      app.UseAuthentication();
      app.UseAuthorization();

      app.MapGet("/health", () => Results.Ok(new { status = "healthy" }))
          .AllowAnonymous();

      app.MapGet("/api/whoami", (ClaimsPrincipal user) =>
      {
        List<ClaimEntry> claims = user.Claims.Select(c => new ClaimEntry(c.Type, c.Value)).ToList();
        return Results.Ok(new
        {
          subject = user.FindFirstValue(ClaimTypes.NameIdentifier) ?? user.FindFirstValue("sub"),
          name = user.FindFirstValue("name") ?? user.FindFirstValue(ClaimTypes.Name),
          claims,
        });
      }).RequireAuthorization();

      app.Run();
    }
  }
}