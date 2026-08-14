# Grafana Dashboard Exporter

A Bash script to export the EVCC dashboards using the Grafana V2 API. Exported dashboards are saved as JSON files suitable for sharing and importing into other Grafana instances.

## Features

- Exports dashboards using Grafana's V2 API (`/apis/dashboard.grafana.app/v2/`)
- Configurable via environment variables, `.env` file, or command-line arguments
- Exports multiple dashboards in a single run
- Outputs properly formatted JSON files

## Requirements

- **bash** (version 4.0+)
- **curl**
- **jq**

## Installation

1. Clone or copy the script to your desired location
2. Make the script executable:
   ```bash
   chmod +x export-dashboards.sh
   ```
3. Copy the example configuration file:
   ```bash
   cp .env.example .env
   ```
4. Edit `.env` with your Grafana server details

## Configuration

### Using `.env` file (recommended)

Create a `.env` file in the same directory as the script:

```bash
# Grafana server URL
GRAFANA_URL="http://localhost:3000"

# Grafana authentication
GRAFANA_USER="admin"
GRAFANA_PASSWORD="your-password"

# Grafana namespace (for V2 API)
GRAFANA_NAMESPACE="default"

# Output directory for exported dashboards
OUTPUT_DIR="./exported-dashboards"
```

### Using environment variables

```bash
export GRAFANA_URL="http://grafana.example.com:3000"
export GRAFANA_USER="admin"
export GRAFANA_PASSWORD="secret"
./export-dashboards.sh
```

### Using command-line arguments

```bash
./export-dashboards.sh \
  --url http://grafana.example.com:3000 \
  --user admin \
  --password secret \
  --namespace default \
  --output ./my-dashboards
```

## Usage

```
Usage: export-dashboards.sh [OPTIONS]

Export Grafana 13 dashboards using the V2 API.

Options:
    -u, --url URL          Grafana server URL (default: http://localhost:3000)
    -U, --user USER        Grafana username (default: admin)
    -p, --password PASS    Grafana password
    -n, --namespace NS     Grafana namespace (default: default)
    -o, --output DIR       Output directory (default: ./exported-dashboards)
    -e, --env FILE         Path to .env file (default: ./.env)
    -h, --help             Show help message
```

### Examples

Export dashboards using defaults from `.env`:
```bash
./export-dashboards.sh
```

Export to a specific directory:
```bash
./export-dashboards.sh --output /path/to/dashboards
```

Use a different configuration file:
```bash
./export-dashboards.sh --env /path/to/production.env
```

## Exported Dashboards

The script exports the following dashboards by default:

| UID       | Filename            | Description        |
|-----------|---------------------|--------------------|
| ad5ks8d   | today-mobile.json   | Mobile view        |
| adddvtj   | today-details.json  | Detailed view      |
| adsmz7v   | today.json          | Today overview     |
| adz6thx   | month.json          | Monthly overview   |

To modify the list of dashboards, edit the `DASHBOARDS` associative array in the script:

```bash
declare -A DASHBOARDS=(
    ["your-uid"]="your-filename.json"
    ["another-uid"]="another-filename.json"
)
```

## Output Format

Exported dashboards are saved as formatted JSON files using the Grafana V2 API response format. These files can be imported directly into another Grafana instance.

## Troubleshooting

### Authentication errors

- Verify your username and password are correct
- Check that the user has permission to view dashboards
- For Grafana Cloud, you may need to use an API key instead

### Dashboard not found

- Verify the dashboard UID is correct
- Check that the namespace is correct (usually `default`)
- Ensure the dashboard exists and is accessible to the user

### Connection errors

- Verify the Grafana URL is correct and accessible
- Check firewall rules if connecting to a remote server
- Ensure Grafana is running and healthy