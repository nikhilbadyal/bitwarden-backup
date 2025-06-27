import React from "react";
import { Dialog, DialogTitle, DialogContent, DialogActions, Button, Typography, Box, IconButton, Tooltip } from "@mui/material";
import DeleteIcon from "@mui/icons-material/Delete";
import RestoreIcon from "@mui/icons-material/Restore";
import { format } from "date-fns";

function BackupDetailsModal({ open, handleClose, backup, formatBytes, handleDelete, handleRestore }) {
  if (!backup) {
    return null;
  }

  const formatFullDate = (dateString) => {
    try {
      return format(new Date(dateString), "dd MMM yyyy hh:mm a");
    } catch (error) {
      return "Invalid date";
    }
  };

  return (
    <Dialog open={open} onClose={handleClose} maxWidth="sm" fullWidth>
      <DialogTitle>Backup Details: {backup.name}</DialogTitle>
      <DialogContent dividers>
        <Box sx={{ mb: 2 }}>
          <Typography variant="subtitle1" component="span" sx={{ fontWeight: "bold" }}>
            Name:
          </Typography>
          <Typography variant="body1" component="span">
            {" "}
            {backup.name}
          </Typography>
        </Box>
        <Box sx={{ mb: 2 }}>
          <Typography variant="subtitle1" component="span" sx={{ fontWeight: "bold" }}>
            Size:
          </Typography>
          <Typography variant="body1" component="span">
            {" "}
            {formatBytes(backup.size)}
          </Typography>
        </Box>
        <Box sx={{ mb: 2 }}>
          <Typography variant="subtitle1" component="span" sx={{ fontWeight: "bold" }}>
            Modified Time:
          </Typography>
          <Typography variant="body1" component="span">
            {" "}
            {formatFullDate(backup.mod_time)}
          </Typography>
        </Box>
        {backup.checksum && (
          <Box sx={{ mb: 2 }}>
            <Typography variant="subtitle1" component="span" sx={{ fontWeight: "bold" }}>
              Checksum:
            </Typography>
            <Typography variant="body1" component="span">
              {" "}
              {backup.checksum}
            </Typography>
          </Box>
        )}
        {backup.backup_type && (
          <Box sx={{ mb: 2 }}>
            <Typography variant="subtitle1" component="span" sx={{ fontWeight: "bold" }}>
              Backup Type:
            </Typography>
            <Typography variant="body1" component="span">
              {" "}
              {backup.backup_type}
            </Typography>
          </Box>
        )}
      </DialogContent>
      <DialogActions>
        <Tooltip title="Restore">
          <IconButton onClick={() => handleRestore(backup.name)} color="primary">
            <RestoreIcon />
          </IconButton>
        </Tooltip>
        <Tooltip title="Delete">
          <IconButton onClick={() => handleDelete(backup.name)} color="error">
            <DeleteIcon />
          </IconButton>
        </Tooltip>
        <Button onClick={handleClose}>Close</Button>
      </DialogActions>
    </Dialog>
  );
}

export default BackupDetailsModal;
