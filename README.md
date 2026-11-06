# Create a varibale group for secrets

In Azure pipelines create a variable group called "e2e-secrets", add the following values:

| Name | Wert |
|------|------|
| copilotToken | The token the copilot cli uses for authentication |
| e2eUser | The username for the end-to-end tests |
| e2ePassword | The password for the end-to-end test user |

# Create a Github Copilot token
Step 1: Generate the Token
Navigate to GitHub Settings > Developer settings > Personal access tokens > Fine-grained tokens. 
Click Generate new token. 
Configure the token with the following settings:
Token name: e.g., copilot-cli-actions.
Expiration: Set to 90 days or your security policy limit.
Repository access: Select Only select repositories and choose the specific repos where the pipeline runs.
Permissions: Click Add permissions and select:
Copilot Requests: Read (required).
Public Repositoriy access
Click Generate token and copy the value immediately (it starts with github_pat_).
