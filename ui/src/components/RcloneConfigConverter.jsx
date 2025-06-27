import React, { useState } from "react";
import { Paper, Typography, TextField, Button, Box, CircularProgress } from "@mui/material";

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || "http://localhost:5050";

function RcloneConfigConverter({ token }) {
  const [rawConfig, setRawConfig] = useState("");
  const [base64Config, setBase64Config] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const handleConvert = () => {
    if (!rawConfig) {
      setError("Please enter rclone config content.");
      return;
    }
    setLoading(true);
    setError("");
    setBase64Config("");

    fetch(`${API_BASE_URL}/api/v1/backups/rclone/config/base64`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "text/plain", // Important: send as plain text
      },
      body: rawConfig,
    })
      .then((response) => {
        if (!response.ok) {
          return response.json().then((err) => {
            throw new Error(err.detail || `HTTP error! status: ${response.status}`);
          });
        }
        return response.json();
      })
      .then((data) => {
        setBase64Config(data.base64_config);
      })
      .catch((err) => {
        console.error("Error converting config:", err);
        setError(`Failed to convert config: ${err.message}`);
      })
      .finally(() => {
        setLoading(false);
      });
  };

  return (
    <Paper elevation={3} sx={{ p: 3 }}>
      <Typography variant="h4" gutterBottom>
        Rclone Config to Base64
      </Typography>
      <Typography variant="body1" sx={{ mb: 2 }}>
        Paste your raw rclone.conf content below to convert it to a base64 encoded string. This is useful for setting the `RCLONE_CONFIG_BASE64`
        environment variable.
      </Typography>

      <TextField
        label="Raw Rclone Config Content"
        multiline
        rows={10}
        fullWidth
        value={rawConfig}
        onChange={(e) => setRawConfig(e.target.value)}
        variant="outlined"
        sx={{ mb: 2 }}
        placeholder="[remote_name]\ntype = s3\naccess_key_id = YOUR_ACCESS_KEY\nsecret_access_key = YOUR_SECRET_KEY"
      />

      <Button variant="contained" onClick={handleConvert} disabled={loading} sx={{ mb: 2 }}>
        {loading ? <CircularProgress size={24} /> : "Convert to Base64"}
      </Button>

      {error && (
        <Typography color="error" sx={{ mb: 2 }}>
          {error}
        </Typography>
      )}

      {base64Config && (
        <Box>
          <Typography variant="h6" gutterBottom>
            Base64 Encoded Config
          </Typography>
          <TextField
            label="Base64 Output"
            multiline
            rows={5}
            fullWidth
            value={base64Config}
            variant="outlined"
            InputProps={{
              readOnly: true,
            }}
            sx={{ mb: 2 }}
          />
          <Button variant="outlined" onClick={() => navigator.clipboard.writeText(base64Config)}>
            Copy to Clipboard
          </Button>
        </Box>
      )}
    </Paper>
  );
}

export default RcloneConfigConverter;
