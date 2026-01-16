import React, { useState, useEffect, useCallback } from "react";
import { Card, CardContent, Typography, Grid, CircularProgress, Paper, Button, Box } from "@mui/material";
import ClearAllIcon from "@mui/icons-material/ClearAll";

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || "http://localhost:5050";

function Health({ token }) {
  const [healthData, setHealthData] = useState(null);
  const [infoData, setInfoData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const fetchHealthAndInfo = useCallback(async () => {
    try {
      // Fetch health data from /status
      const healthResponse = await fetch(`${API_BASE_URL}/status`, {
        headers: {
          Authorization: `Bearer ${token}`,
        },
      });
      if (!healthResponse.ok) {
        throw new Error(`HTTP error! status: ${healthResponse.status}`);
      }
      const healthJson = await healthResponse.json();
      setHealthData(healthJson);

      // Fetch info data from /info
      const infoResponse = await fetch(`${API_BASE_URL}/info`, {
        headers: {
          Authorization: `Bearer ${token}`,
        },
      });
      if (!infoResponse.ok) {
        throw new Error(`HTTP error! status: ${infoResponse.status}`);
      }
      const infoJson = await infoResponse.json();
      setInfoData(infoJson);
    } catch (err) {
      console.error("Error fetching data:", err);
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [token, setHealthData, setInfoData, setError, setLoading]);

  useEffect(() => {
    fetchHealthAndInfo();
  }, [token, fetchHealthAndInfo]);

  const handleClearCache = async () => {
    if (window.confirm("Are you sure you want to clear the system cache? This operation cannot be undone.")) {
      try {
        const response = await fetch(`${API_BASE_URL}/maintenance/cache/clear/`, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
          },
        });
        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }
        const data = await response.json();
        alert(data.message);
      } catch (err) {
        console.error("Error clearing cache:", err);
        alert(`Failed to clear cache: ${err.message}`);
      }
    }
  };

  if (loading) {
    return <CircularProgress />;
  }

  if (error) {
    return <Typography color="error">Error: {error}</Typography>;
  }

  return (
    <Paper elevation={3} sx={{ p: 3 }}>
      <Typography variant="h4" gutterBottom>
        System Health Dashboard
      </Typography>

      <Box sx={{ mb: 3, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <Button variant="contained" color="primary" startIcon={<ClearAllIcon />} onClick={handleClearCache}>
          Clear System Cache
        </Button>
      </Box>

      {healthData && infoData ? (
        <Grid container spacing={3}>
          {/* Overall Status */}
          <Grid item xs={12}>
            <Card
              sx={{ bgcolor: healthData.overall_status === "healthy" ? "#e8f5e9" : healthData.overall_status === "degraded" ? "#fff3e0" : "#ffebee" }}
            >
              <CardContent>
                <Typography variant="h5" component="div" sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                  Overall System Status:
                  <Typography
                    variant="h5"
                    component="span"
                    color={
                      healthData.overall_status === "healthy"
                        ? "success.main"
                        : healthData.overall_status === "degraded"
                          ? "warning.main"
                          : "error.main"
                    }
                  >
                    {healthData.overall_status.toUpperCase()}
                  </Typography>
                </Typography>
                <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>
                  Last updated: {new Date(healthData.timestamp).toLocaleString()}
                </Typography>
              </CardContent>
            </Card>
          </Grid>

          {/* Component Health */}
          <Grid item xs={12} md={6}>
            <Card>
              <CardContent>
                <Typography variant="h6" gutterBottom>
                  Component Health
                </Typography>
                <Box sx={{ mb: 2 }}>
                  <Typography variant="subtitle1">Redis:</Typography>
                  <Typography color={healthData.components.redis.status === "ok" ? "success.main" : "error.main"}>
                    {healthData.components.redis.status.toUpperCase()}
                  </Typography>
                  {healthData.components.redis.response_time_ms && (
                    <Typography variant="body2">Response Time: {healthData.components.redis.response_time_ms.toFixed(2)} ms</Typography>
                  )}
                </Box>
                <Box>
                  <Typography variant="subtitle1">Rclone:</Typography>
                  <Typography color={healthData.components.rclone.status === "ok" ? "success.main" : "error.main"}>
                    {healthData.components.rclone.status.toUpperCase()}
                  </Typography>
                  {healthData.components.rclone.response_time_ms && (
                    <Typography variant="body2">Response Time: {healthData.components.rclone.response_time_ms.toFixed(2)} ms</Typography>
                  )}
                </Box>
              </CardContent>
            </Card>
          </Grid>

          {/* System Information */}
          <Grid item xs={12} md={6}>
            <Card>
              <CardContent>
                <Typography variant="h6" gutterBottom>
                  System Information
                </Typography>
                <Typography variant="body1">
                  <strong>Uptime:</strong> {healthData.uptime_seconds.toFixed(0)} seconds
                </Typography>
                <Typography variant="body1">
                  <strong>API Version:</strong> {infoData.api.version}
                </Typography>
                <Typography variant="body1">
                  <strong>Rclone Version:</strong> {infoData.tools.rclone.version}
                </Typography>
                <Typography variant="body1">
                  <strong>Python Version:</strong> {infoData.runtime.python.version}
                </Typography>
                <Typography variant="body1">
                  <strong>FastAPI Version:</strong> {infoData.runtime.fastapi.version}
                </Typography>
                <Typography variant="body1">
                  <strong>Backup Path:</strong> {infoData.server.backup_path}
                </Typography>
              </CardContent>
            </Card>
          </Grid>
        </Grid>
      ) : (
        <Typography>Could not load health data.</Typography>
      )}
    </Paper>
  );
}

export default Health;
