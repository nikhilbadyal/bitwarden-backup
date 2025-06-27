import React, { useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { Box, Button, TextField, Typography, Paper } from "@mui/material";

function Login({ setToken }) {
  const [tokenInput, setTokenInput] = useState("");
  const navigate = useNavigate();
  const location = useLocation();

  const from = location.state?.from?.pathname || "/";

  const handleSubmit = (e) => {
    e.preventDefault();
    setToken(tokenInput);
    navigate(from, { replace: true });
  };

  return (
    <Box
      sx={{
        display: "flex",
        justifyContent: "center",
        alignItems: "center",
        height: "100vh",
      }}
    >
      <Paper elevation={3} sx={{ p: 4, width: "100%", maxWidth: 400 }}>
        <Typography variant="h4" gutterBottom align="center">
          Login
        </Typography>
        <Typography variant="subtitle1" gutterBottom align="center" sx={{ mb: 2 }}>
          Enter your API Token to continue
        </Typography>
        <form onSubmit={handleSubmit}>
          <TextField
            label="API Token"
            variant="outlined"
            fullWidth
            value={tokenInput}
            onChange={(e) => setTokenInput(e.target.value)}
            sx={{ mb: 2 }}
          />
          <Button type="submit" variant="contained" fullWidth>
            Login
          </Button>
        </form>
      </Paper>
    </Box>
  );
}

export default Login;
