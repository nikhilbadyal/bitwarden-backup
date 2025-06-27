import React, { useState, useEffect, useCallback } from "react";
import {
  Typography,
  CircularProgress,
  Paper,
  Button,
  Box,
  Chip,
  Collapse,
  IconButton,
  Card,
  CardContent,
  CardActions,
  Grid,
  LinearProgress,
} from "@mui/material";
import CheckCircleIcon from "@mui/icons-material/CheckCircle";
import ErrorIcon from "@mui/icons-material/Error";
import WarningIcon from "@mui/icons-material/Warning";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";
import ExpandLessIcon from "@mui/icons-material/ExpandLess";
import RefreshIcon from "@mui/icons-material/Refresh";

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || "http://localhost:5050";

function Remotes({ token }) {
  const [remotes, setRemotes] = useState([]);
  const [remoteStatuses, setRemoteStatuses] = useState({});
  const [remoteUsages, setRemoteUsages] = useState({});
  const [loadingRemotes, setLoadingRemotes] = useState(true);
  const [checkingAll, setCheckingAll] = useState(false);
  const [expandedRemote, setExpandedRemote] = useState(null);
  const [checkingIndividual, setCheckingIndividual] = useState({});

  const fetchRemotes = useCallback(() => {
    setLoadingRemotes(true);
    fetch(`${API_BASE_URL}/api/v1/remotes`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    })
      .then((response) => response.json())
      .then((data) => {
        setRemotes(data.remotes || []);
        setLoadingRemotes(false);
      })
      .catch((error) => {
        console.error("Error fetching remotes:", error);
        setLoadingRemotes(false);
      });
  }, [token, setLoadingRemotes, setRemotes]);

  useEffect(() => {
    fetchRemotes();
  }, [token, fetchRemotes]);

  const checkAllRemotes = () => {
    setCheckingAll(true);
    setRemoteStatuses({}); // Clear previous statuses
    fetch(`${API_BASE_URL}/api/v1/remotes/check-all`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    })
      .then((response) => response.json())
      .then((data) => {
        const newStatuses = {};
        data.results.forEach((result) => {
          newStatuses[result.remote] = result;
        });
        setRemoteStatuses(newStatuses);
        setCheckingAll(false);
      })
      .catch((error) => {
        console.error("Error checking all remotes:", error);
        setCheckingAll(false);
      });
  };

  const checkIndividualRemote = (remote) => {
    setCheckingIndividual((prev) => ({ ...prev, [remote]: true }));
    fetch(`${API_BASE_URL}/api/v1/remotes/${remote}/check`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    })
      .then((response) => response.json())
      .then((data) => {
        setRemoteStatuses((prev) => ({ ...prev, [remote]: data }));
      })
      .catch((error) => {
        console.error(`Error checking remote ${remote}:`, error);
        setRemoteStatuses((prev) => ({ ...prev, [remote]: { status: "error", message: "Failed to check", remote_name: remote } }));
      })
      .finally(() => {
        setCheckingIndividual((prev) => ({ ...prev, [remote]: false }));
      });
  };

  const fetchRemoteUsage = (remote) => {
    setRemoteUsages((prev) => ({ ...prev, [remote]: { loading: true } }));
    fetch(`${API_BASE_URL}/api/v1/remotes/${remote}/usage`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    })
      .then((response) => response.json())
      .then((data) => {
        setRemoteUsages((prev) => ({ ...prev, [remote]: { ...data, loading: false } }));
      })
      .catch((error) => {
        console.error(`Error fetching usage for ${remote}:`, error);
        setRemoteUsages((prev) => ({ ...prev, [remote]: { error: "Failed to fetch usage", loading: false } }));
      });
  };

  const handleExpandClick = (remote) => {
    if (expandedRemote === remote) {
      setExpandedRemote(null);
    } else {
      setExpandedRemote(remote);
      if (!remoteUsages[remote] || remoteUsages[remote].error) {
        fetchRemoteUsage(remote);
      }
    }
  };

  const getStatusChip = (status) => {
    switch (status) {
      case "ok":
        return <Chip label="Reachable" color="success" icon={<CheckCircleIcon />} size="small" />;
      case "error":
        return <Chip label="Error" color="error" icon={<ErrorIcon />} size="small" />;
      case "unavailable":
        return <Chip label="Unavailable" color="warning" icon={<WarningIcon />} size="small" />;
      default:
        return <Chip label="Unknown" size="small" />;
    }
  };

  const formatBytes = (bytes) => {
    if (bytes === 0) return "0 Bytes";
    if (bytes === null || bytes === undefined) return "N/A";
    const k = 1024;
    const sizes = ["Bytes", "KB", "MB", "GB", "TB", "PB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
  };

  if (loadingRemotes) {
    return <CircularProgress />;
  }

  return (
    <Paper elevation={3} sx={{ p: 3 }}>
      <Typography variant="h4" gutterBottom>
        Configured Remotes
      </Typography>
      <Box sx={{ mb: 3 }}>
        <Button variant="contained" onClick={checkAllRemotes} disabled={checkingAll || remotes.length === 0}>
          {checkingAll ? <CircularProgress size={24} /> : "Check All Remotes"}
        </Button>
      </Box>
      {remotes.length > 0 ? (
        <Grid container spacing={3}>
          {remotes.map((remote) => (
            <Grid item xs={12} sm={6} md={4} key={remote}>
              <Card sx={{ height: "100%", display: "flex", flexDirection: "column" }}>
                <CardContent sx={{ flexGrow: 1 }}>
                  <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 1 }}>
                    <Typography variant="h6" component="div">
                      {remote}
                    </Typography>
                    {remoteStatuses[remote] ? getStatusChip(remoteStatuses[remote].status) : <Chip label="Not checked" size="small" />}
                  </Box>
                  {remoteStatuses[remote] && (
                    <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
                      {remoteStatuses[remote].message}
                      {remoteStatuses[remote].response_time_ms && ` (${remoteStatuses[remote].response_time_ms.toFixed(0)} ms)`}
                    </Typography>
                  )}
                  <Collapse in={expandedRemote === remote} timeout="auto" unmountOnExit>
                    <Box sx={{ mt: 2 }}>
                      {remoteUsages[remote] && remoteUsages[remote].loading ? (
                        <CircularProgress size={20} />
                      ) : remoteUsages[remote] && remoteUsages[remote].error ? (
                        <Typography color="error">{remoteUsages[remote].error}</Typography>
                      ) : remoteUsages[remote] && remoteUsages[remote].total !== undefined ? (
                        <Box>
                          <Typography variant="body2">
                            <strong>Used:</strong> {formatBytes(remoteUsages[remote].used)}
                          </Typography>
                          <Typography variant="body2">
                            <strong>Total:</strong> {formatBytes(remoteUsages[remote].total)}
                          </Typography>
                          <Typography variant="body2">
                            <strong>Free:</strong> {formatBytes(remoteUsages[remote].free)}
                          </Typography>
                          {remoteUsages[remote].usage_percentage !== null && (
                            <Box sx={{ mt: 1 }}>
                              <LinearProgress
                                variant="determinate"
                                value={remoteUsages[remote].usage_percentage}
                                sx={{ height: 8, borderRadius: 5 }}
                              />
                              <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5 }}>
                                {remoteUsages[remote].usage_percentage}% used
                              </Typography>
                            </Box>
                          )}
                        </Box>
                      ) : (
                        <Typography variant="body2" color="text.secondary">
                          Usage information not available or not supported.
                        </Typography>
                      )}
                    </Box>
                  </Collapse>
                </CardContent>
                <CardActions sx={{ justifyContent: "flex-end", pt: 0 }}>
                  <Button
                    size="small"
                    onClick={() => checkIndividualRemote(remote)}
                    disabled={checkingIndividual[remote]}
                    startIcon={checkingIndividual[remote] ? <CircularProgress size={16} /> : <RefreshIcon />}
                  >
                    Check
                  </Button>
                  <IconButton onClick={() => handleExpandClick(remote)} size="small">
                    {expandedRemote === remote ? <ExpandLessIcon /> : <ExpandMoreIcon />}
                  </IconButton>
                </CardActions>
              </Card>
            </Grid>
          ))}
        </Grid>
      ) : (
        <Typography>No remotes found.</Typography>
      )}
    </Paper>
  );
}

export default Remotes;
