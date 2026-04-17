import React, { useState, useEffect } from "react";
import { BrowserRouter as Router, Routes, Route, Link, Navigate } from "react-router-dom";
import { Box, CssBaseline, Drawer, AppBar, Toolbar, List, ListItem, ListItemIcon, ListItemText, Typography, Divider, Button } from "@mui/material";
import { HealthAndSafety, Backup, Cloud, ExitToApp, Settings, PlayCircle } from "@mui/icons-material";
import Health from "./components/Health";
import Remotes from "./components/Remotes";
import Backups from "./components/Backups";
import BackupJobs from "./components/BackupJobs";
import Login from "./components/Login";
import PrivateRoute from "./components/PrivateRoute";
import RcloneConfigConverter from "./components/RcloneConfigConverter";
import logo from "./full-logo.svg";

const drawerWidth = 240;

// Error Boundary Component
class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error) {
    return { hasError: true, error };
  }

  componentDidCatch(error, errorInfo) {
    console.error("Error caught by boundary:", error, errorInfo);
  }

  render() {
    if (this.state.hasError) {
      return (
        <div style={{ padding: "20px", color: "red", backgroundColor: "#ffe6e6" }}>
          <h2>Something went wrong:</h2>
          <pre>{this.state.error?.toString()}</pre>
        </div>
      );
    }

    return this.props.children;
  }
}

function App() {
  // Keep token in sessionStorage so it is not persisted beyond browser session lifetime.
  const [token, setToken] = useState(() => {
    try {
      // Read any existing in-session token for page refresh continuity.
      return sessionStorage.getItem("api_token");
    } catch {
      // Fall back to unauthenticated state if storage is unavailable.
      return null;
    }
  });

  useEffect(() => {
    // Synchronize token updates to sessionStorage for same-session continuity.
    try {
      if (token) {
        // Persist authenticated token only for the current browser session.
        sessionStorage.setItem("api_token", token);
      } else {
        // Remove token value from storage when user logs out.
        sessionStorage.removeItem("api_token");
      }
    } catch {
      // Ignore storage write failures and keep in-memory token as fallback.
    }
  }, [token]);

  const handleLogout = () => {
    // Clear token state to terminate authenticated UI access immediately.
    setToken(null);
  };

  const menuItems = [
    { text: "Health", icon: <HealthAndSafety />, path: "/health" },
    { text: "Backup Jobs", icon: <PlayCircle />, path: "/jobs" },
    { text: "Remotes", icon: <Cloud />, path: "/remotes" },
    { text: "Backups", icon: <Backup />, path: "/backups" },
    { text: "Rclone Config", icon: <Settings />, path: "/rclone-config" },
  ];

  return (
    <ErrorBoundary>
      <Router>
        <Routes>
          <Route path="/login" element={<Login setToken={setToken} />} />
          <Route
            path="/*"
            element={
              <PrivateRoute token={token}>
                <MainLayout menuItems={menuItems} handleLogout={handleLogout} token={token} />
              </PrivateRoute>
            }
          />
        </Routes>
      </Router>
    </ErrorBoundary>
  );
}

function MainLayout({ menuItems, handleLogout, token }) {
  return (
    <ErrorBoundary>
      <Box sx={{ display: "flex" }}>
        <CssBaseline />
        <AppBar position="fixed" sx={{ zIndex: (theme) => theme.zIndex.drawer + 1 }}>
          <Toolbar>
            <img src={logo} alt="Bitwarden Backup Logo" style={{ height: "36px", marginRight: "16px" }} />
            <Typography variant="h6" noWrap component="div" sx={{ flexGrow: 1 }}>
              VαultSync
            </Typography>
            <Button color="inherit" onClick={handleLogout} startIcon={<ExitToApp />}>
              Logout
            </Button>
          </Toolbar>
        </AppBar>
        <Drawer
          variant="permanent"
          sx={{
            width: drawerWidth,
            flexShrink: 0,
            "& .MuiDrawer-paper": { width: drawerWidth, boxSizing: "border-box" },
          }}
        >
          <Toolbar />
          <Box sx={{ overflow: "auto" }}>
            <List>
              {menuItems.map((item) => (
                <ListItem component={Link} to={item.path} key={item.text} sx={{ cursor: "pointer" }}>
                  <ListItemIcon>{item.icon}</ListItemIcon>
                  <ListItemText primary={item.text} />
                </ListItem>
              ))}
            </List>
            <Divider />
          </Box>
        </Drawer>
        <Box component="main" sx={{ flexGrow: 1, p: 3 }}>
          <Toolbar />
          <Routes>
            <Route path="/" element={<Navigate to="/health" />} />
            <Route path="/health" element={<Health token={token} />} />
            <Route path="/jobs" element={<BackupJobs token={token} />} />
            <Route path="/remotes" element={<Remotes token={token} />} />
            <Route path="/backups" element={<Backups token={token} />} />
            <Route path="/rclone-config" element={<RcloneConfigConverter token={token} />} />
          </Routes>
        </Box>
      </Box>
    </ErrorBoundary>
  );
}

export default App;
