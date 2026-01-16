import React, { useState, useEffect, useCallback, useRef } from "react";
import {
  Paper,
  Typography,
  Button,
  Box,
  Card,
  CardContent,
  LinearProgress,
  Chip,
  List,
  ListItem,
  ListItemText,
  IconButton,
  Collapse,
  Alert,
  CircularProgress,
  Tooltip,
  Divider,
} from "@mui/material";
import PlayArrowIcon from "@mui/icons-material/PlayArrow";
import RefreshIcon from "@mui/icons-material/Refresh";
import CancelIcon from "@mui/icons-material/Cancel";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";
import ExpandLessIcon from "@mui/icons-material/ExpandLess";
import CheckCircleIcon from "@mui/icons-material/CheckCircle";
import ErrorIcon from "@mui/icons-material/Error";
import HourglassEmptyIcon from "@mui/icons-material/HourglassEmpty";
import SyncIcon from "@mui/icons-material/Sync";
import BlockIcon from "@mui/icons-material/Block";
import { formatDistanceToNow, parseISO } from "date-fns";

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || "http://localhost:5050";

const statusConfig = {
  pending: { color: "default", icon: <HourglassEmptyIcon />, label: "Pending" },
  running: { color: "primary", icon: <SyncIcon className="spin" />, label: "Running" },
  completed: { color: "success", icon: <CheckCircleIcon />, label: "Completed" },
  failed: { color: "error", icon: <ErrorIcon />, label: "Failed" },
  cancelled: { color: "warning", icon: <BlockIcon />, label: "Cancelled" },
};

const logLevelColors = {
  INFO: "#2196f3",
  WARN: "#ff9800",
  ERROR: "#f44336",
  SUCCESS: "#4caf50",
  DEBUG: "#9e9e9e",
};

function BackupJobs({ token }) {
  const [jobs, setJobs] = useState([]);
  const [loading, setLoading] = useState(true);
  const [triggeringBackup, setTriggeringBackup] = useState(false);
  const [activeJobId, setActiveJobId] = useState(null);
  const [activeJobLogs, setActiveJobLogs] = useState([]);
  const [activeJobStatus, setActiveJobStatus] = useState(null);
  const [expandedJobId, setExpandedJobId] = useState(null);
  const [error, setError] = useState(null);
  const eventSourceRef = useRef(null);
  const logsEndRef = useRef(null);

  // Fetch jobs list
  const fetchJobs = useCallback(async () => {
    try {
      const response = await fetch(`${API_BASE_URL}/api/v1/jobs?limit=20`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      setJobs(data.jobs || []);
      setError(null);
    } catch (err) {
      console.error("Error fetching jobs:", err);
      setError("Failed to load backup jobs");
    } finally {
      setLoading(false);
    }
  }, [token]);

  useEffect(() => {
    fetchJobs();
    // Poll for updates every 10 seconds
    const interval = setInterval(fetchJobs, 10000);
    return () => clearInterval(interval);
  }, [fetchJobs]);

  // Auto-scroll logs
  useEffect(() => {
    if (logsEndRef.current) {
      logsEndRef.current.scrollIntoView({ behavior: "smooth" });
    }
  }, [activeJobLogs]);

  // Subscribe to job updates via SSE
  const subscribeToJob = useCallback(
    (jobId) => {
      // Close existing connection
      if (eventSourceRef.current) {
        eventSourceRef.current.close();
      }

      setActiveJobId(jobId);
      setActiveJobLogs([]);
      setActiveJobStatus(null);

      // Create SSE connection
      const eventSource = new EventSource(`${API_BASE_URL}/api/v1/jobs/${jobId}/stream?token=${token}`);
      eventSourceRef.current = eventSource;

      eventSource.addEventListener("status", (event) => {
        const data = JSON.parse(event.data);
        setActiveJobStatus(data);
      });

      eventSource.addEventListener("log", (event) => {
        const data = JSON.parse(event.data);
        setActiveJobLogs((prev) => [...prev, data]);
      });

      eventSource.addEventListener("done", (event) => {
        const data = JSON.parse(event.data);
        setActiveJobStatus((prev) => ({ ...prev, ...data }));
        eventSource.close();
        eventSourceRef.current = null;
        // Refresh job list
        fetchJobs();
      });

      eventSource.addEventListener("error", () => {
        console.error("SSE connection error");
        eventSource.close();
        eventSourceRef.current = null;
      });

      return () => {
        eventSource.close();
        eventSourceRef.current = null;
      };
    },
    [token, fetchJobs],
  );

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (eventSourceRef.current) {
        eventSourceRef.current.close();
      }
    };
  }, []);

  // Trigger new backup
  const handleTriggerBackup = async () => {
    setTriggeringBackup(true);
    setError(null);

    try {
      const response = await fetch(`${API_BASE_URL}/api/v1/jobs/trigger`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
      });

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        throw new Error(errorData.detail || `HTTP ${response.status}`);
      }

      const data = await response.json();

      // Subscribe to the new job
      subscribeToJob(data.job_id);

      // Refresh job list
      fetchJobs();
    } catch (err) {
      console.error("Error triggering backup:", err);
      setError(`Failed to trigger backup: ${err.message}`);
    } finally {
      setTriggeringBackup(false);
    }
  };

  // Cancel a job
  const handleCancelJob = async (jobId) => {
    if (!window.confirm("Are you sure you want to cancel this backup job?")) return;

    try {
      const response = await fetch(`${API_BASE_URL}/api/v1/jobs/${jobId}/cancel`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
      });

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        throw new Error(errorData.detail || `HTTP ${response.status}`);
      }

      fetchJobs();
    } catch (err) {
      console.error("Error cancelling job:", err);
      alert(`Failed to cancel job: ${err.message}`);
    }
  };

  // Fetch logs for a completed job
  const fetchJobLogs = async (jobId) => {
    try {
      const response = await fetch(`${API_BASE_URL}/api/v1/jobs/${jobId}/logs?limit=500`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      return data.logs || [];
    } catch (err) {
      console.error("Error fetching logs:", err);
      return [];
    }
  };

  // Toggle job expansion
  const handleToggleExpand = async (jobId) => {
    if (expandedJobId === jobId) {
      setExpandedJobId(null);
    } else {
      setExpandedJobId(jobId);
      const job = jobs.find((j) => j.id === jobId);
      if (job && job.status !== "running" && job.status !== "pending") {
        const logs = await fetchJobLogs(jobId);
        setActiveJobLogs(logs);
      }
    }
  };

  // Watch a running job
  const handleWatchJob = (jobId) => {
    subscribeToJob(jobId);
    setExpandedJobId(jobId);
  };

  const formatDate = (dateString) => {
    if (!dateString) return "N/A";
    try {
      return formatDistanceToNow(parseISO(dateString), { addSuffix: true });
    } catch {
      return dateString;
    }
  };

  if (loading) {
    return (
      <Paper elevation={3} sx={{ p: 3, display: "flex", justifyContent: "center" }}>
        <CircularProgress />
      </Paper>
    );
  }

  return (
    <Paper elevation={3} sx={{ p: 3 }}>
      <Typography variant="h4" gutterBottom>
        Backup Jobs
      </Typography>

      <Box sx={{ mb: 3, display: "flex", gap: 2, alignItems: "center" }}>
        <Button
          variant="contained"
          color="primary"
          startIcon={triggeringBackup ? <CircularProgress size={20} color="inherit" /> : <PlayArrowIcon />}
          onClick={handleTriggerBackup}
          disabled={triggeringBackup}
        >
          {triggeringBackup ? "Starting..." : "Trigger New Backup"}
        </Button>
        <Button variant="outlined" startIcon={<RefreshIcon />} onClick={fetchJobs}>
          Refresh
        </Button>
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {error}
        </Alert>
      )}

      {/* Active Job Progress */}
      {activeJobId && activeJobStatus && (
        <Card sx={{ mb: 3, bgcolor: "#f5f5f5" }}>
          <CardContent>
            <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
              <Typography variant="h6">
                Active Backup Job
                <Chip
                  size="small"
                  label={statusConfig[activeJobStatus.status]?.label || activeJobStatus.status}
                  color={statusConfig[activeJobStatus.status]?.color || "default"}
                  icon={statusConfig[activeJobStatus.status]?.icon}
                  sx={{ ml: 2 }}
                />
              </Typography>
              {(activeJobStatus.status === "running" || activeJobStatus.status === "pending") && (
                <IconButton color="error" onClick={() => handleCancelJob(activeJobId)} title="Cancel">
                  <CancelIcon />
                </IconButton>
              )}
            </Box>

            <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
              {activeJobStatus.current_step}
            </Typography>

            <Box sx={{ display: "flex", alignItems: "center", gap: 2, mb: 2 }}>
              <LinearProgress variant="determinate" value={activeJobStatus.progress || 0} sx={{ flexGrow: 1, height: 10, borderRadius: 5 }} />
              <Typography variant="body2" fontWeight="bold">
                {activeJobStatus.progress}%
              </Typography>
            </Box>

            {activeJobStatus.error && (
              <Alert severity="error" sx={{ mb: 2 }}>
                {activeJobStatus.error}
              </Alert>
            )}

            {/* Live Logs */}
            <Typography variant="subtitle2" sx={{ mb: 1 }}>
              Logs
            </Typography>
            <Box
              sx={{
                bgcolor: "#1e1e1e",
                color: "#d4d4d4",
                p: 2,
                borderRadius: 1,
                maxHeight: 300,
                overflow: "auto",
                fontFamily: "monospace",
                fontSize: "0.85rem",
              }}
            >
              {activeJobLogs.length === 0 ? (
                <Typography color="grey.500">Waiting for logs...</Typography>
              ) : (
                activeJobLogs.map((log, idx) => (
                  <Box key={idx} sx={{ mb: 0.5 }}>
                    <span style={{ color: "#888" }}>{log.timestamp?.split("T")[1]?.split(".")[0] || ""}</span>
                    <span style={{ color: logLevelColors[log.level] || "#fff", marginLeft: 8, fontWeight: "bold" }}>[{log.level}]</span>
                    <span style={{ marginLeft: 8 }}>{log.message}</span>
                  </Box>
                ))
              )}
              <div ref={logsEndRef} />
            </Box>
          </CardContent>
        </Card>
      )}

      {/* Jobs List */}
      <Typography variant="h6" sx={{ mb: 2 }}>
        Recent Jobs
      </Typography>

      {jobs.length === 0 ? (
        <Typography color="text.secondary">No backup jobs found. Trigger a new backup to get started.</Typography>
      ) : (
        <List>
          {jobs.map((job) => (
            <React.Fragment key={job.id}>
              <ListItem
                sx={{
                  bgcolor: expandedJobId === job.id ? "#f0f0f0" : "transparent",
                  borderRadius: 1,
                  mb: 1,
                  border: "1px solid #e0e0e0",
                }}
                secondaryAction={
                  <Box sx={{ display: "flex", gap: 1 }}>
                    {(job.status === "running" || job.status === "pending") && (
                      <>
                        <Tooltip title="Watch live">
                          <IconButton color="primary" onClick={() => handleWatchJob(job.id)}>
                            <SyncIcon />
                          </IconButton>
                        </Tooltip>
                        <Tooltip title="Cancel">
                          <IconButton color="error" onClick={() => handleCancelJob(job.id)}>
                            <CancelIcon />
                          </IconButton>
                        </Tooltip>
                      </>
                    )}
                    <IconButton onClick={() => handleToggleExpand(job.id)}>
                      {expandedJobId === job.id ? <ExpandLessIcon /> : <ExpandMoreIcon />}
                    </IconButton>
                  </Box>
                }
              >
                <ListItemText
                  primary={
                    <Box sx={{ display: "flex", alignItems: "center", gap: 2 }}>
                      <Chip
                        size="small"
                        label={statusConfig[job.status]?.label || job.status}
                        color={statusConfig[job.status]?.color || "default"}
                        icon={statusConfig[job.status]?.icon}
                      />
                      <Typography variant="body2" color="text.secondary">
                        {job.id.substring(0, 8)}...
                      </Typography>
                      {job.status === "running" && (
                        <Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 150 }}>
                          <LinearProgress variant="determinate" value={job.progress} sx={{ flexGrow: 1, height: 6, borderRadius: 3 }} />
                          <Typography variant="caption">{job.progress}%</Typography>
                        </Box>
                      )}
                    </Box>
                  }
                  secondary={
                    <Typography variant="body2" color="text.secondary">
                      {job.current_step} • Created {formatDate(job.created_at)}
                      {job.completed_at && ` • Completed ${formatDate(job.completed_at)}`}
                    </Typography>
                  }
                />
              </ListItem>

              <Collapse in={expandedJobId === job.id} timeout="auto" unmountOnExit>
                <Box sx={{ pl: 4, pr: 2, pb: 2 }}>
                  {job.error && (
                    <Alert severity="error" sx={{ mb: 2 }}>
                      {job.error}
                    </Alert>
                  )}

                  <Typography variant="subtitle2" sx={{ mb: 1 }}>
                    Job Details
                  </Typography>
                  <Box sx={{ mb: 2 }}>
                    <Typography variant="body2">
                      <strong>ID:</strong> {job.id}
                    </Typography>
                    <Typography variant="body2">
                      <strong>Created:</strong> {job.created_at}
                    </Typography>
                    {job.started_at && (
                      <Typography variant="body2">
                        <strong>Started:</strong> {job.started_at}
                      </Typography>
                    )}
                    {job.completed_at && (
                      <Typography variant="body2">
                        <strong>Completed:</strong> {job.completed_at}
                      </Typography>
                    )}
                  </Box>

                  {job.status !== "pending" && expandedJobId === job.id && activeJobLogs.length > 0 && (
                    <>
                      <Typography variant="subtitle2" sx={{ mb: 1 }}>
                        Logs
                      </Typography>
                      <Box
                        sx={{
                          bgcolor: "#1e1e1e",
                          color: "#d4d4d4",
                          p: 2,
                          borderRadius: 1,
                          maxHeight: 200,
                          overflow: "auto",
                          fontFamily: "monospace",
                          fontSize: "0.8rem",
                        }}
                      >
                        {activeJobLogs.map((log, idx) => (
                          <Box key={idx} sx={{ mb: 0.25 }}>
                            <span style={{ color: logLevelColors[log.level] || "#fff" }}>[{log.level}]</span>
                            <span style={{ marginLeft: 8 }}>{log.message}</span>
                          </Box>
                        ))}
                      </Box>
                    </>
                  )}
                </Box>
              </Collapse>
              <Divider />
            </React.Fragment>
          ))}
        </List>
      )}

      <style>
        {`
          @keyframes spin {
            from { transform: rotate(0deg); }
            to { transform: rotate(360deg); }
          }
          .spin {
            animation: spin 1s linear infinite;
          }
        `}
      </style>
    </Paper>
  );
}

export default BackupJobs;
