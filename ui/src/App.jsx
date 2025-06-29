import React, { useState, useEffect } from "react";
import { BrowserRouter as Router, Routes, Route, Link, Navigate } from "react-router-dom";
import { Box, CssBaseline, Drawer, AppBar, Toolbar, List, ListItem, ListItemIcon, ListItemText, Typography, Divider, Button } from "@mui/material";
import { HealthAndSafety, Backup, Cloud, ExitToApp, Settings } from "@mui/icons-material";
import Health from "./components/Health";
import Remotes from "./components/Remotes";
import Backups from "./components/Backups";
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
  console.log("App component starting to render...");

  const [token, setToken] = useState(() => {
    try {
      return localStorage.getItem("api_token");
    } catch (e) {
      console.error("Error accessing localStorage:", e);
      return null;
    }
  });

  useEffect(() => {
    console.log("App useEffect running, token:", token);
    try {
      if (token) {
        localStorage.setItem("api_token", token);
      } else {
        localStorage.removeItem("api_token");
      }
    } catch (e) {
      console.error("Error setting localStorage:", e);
    }
  }, [token]);

  const handleLogout = () => {
    console.log("Logout clicked");
    setToken(null);
  };

  const menuItems = [
    { text: "Health", icon: <HealthAndSafety />, path: "/health" },
    { text: "Remotes", icon: <Cloud />, path: "/remotes" },
    { text: "Backups", icon: <Backup />, path: "/backups" },
    { text: "Rclone Config", icon: <Settings />, path: "/rclone-config" },
  ];

  console.log("App about to return JSX...");

  return (
    <ErrorBoundary>
      <Router>
        <Routes>
          <Route path="/login" element={<Login setToken={setToken} />} />
          <Route path="/debug" element={<div style={{ padding: "20px" }}>Debug page - Token: {token || "None"}</div>} />
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
  console.log("MainLayout rendering...");

  return (
    <ErrorBoundary>
      <Box sx={{ display: "flex" }}>
        <CssBaseline />
        <AppBar position="fixed" sx={{ zIndex: (theme) => theme.zIndex.drawer + 1 }}>
          <Toolbar>
            <img src={logo} alt="Bitwarden Backup Logo" style={{ height: "36px", marginRight: "16px" }} />
            <Typography variant="h6" noWrap component="div" sx={{ flexGrow: 1 }}>
              Bitwarden Backup UI
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
