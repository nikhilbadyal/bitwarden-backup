import React, { useState, useEffect, useCallback } from "react";
import {
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Paper,
  Typography,
  CircularProgress,
  Select,
  MenuItem,
  FormControl,
  InputLabel,
  Pagination,
  IconButton,
  Tooltip,
  Link as MuiLink,
  Button,
  Checkbox,
  TextField,
  Grid,
} from "@mui/material";
import { AdapterDateFns } from "@mui/x-date-pickers/AdapterDateFns";
import { LocalizationProvider, DatePicker } from "@mui/x-date-pickers";
import { formatDistanceToNow, parseISO, format } from "date-fns";
import FileDownloadIcon from "@mui/icons-material/FileDownload";
import DeleteIcon from "@mui/icons-material/Delete";
import RefreshIcon from "@mui/icons-material/Refresh";
import PlayArrowIcon from "@mui/icons-material/PlayArrow";
import BackupDetailsModal from "./BackupDetailsModal";

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || "http://localhost:5050";

function Backups({ token }) {
  const [backups, setBackups] = useState([]);
  const [remotes, setRemotes] = useState([]);
  const [selectedRemote, setSelectedRemote] = useState("");
  const [loadingBackups, setLoadingBackups] = useState(false);
  const [loadingRemotes, setLoadingRemotes] = useState(true);
  const [page, setPage] = useState(1);
  const pageSize = 20; // Page size is fixed for now
  const [totalPages, setTotalPages] = useState(0);
  const [openModal, setOpenModal] = useState(false);
  const [selectedBackup, setSelectedBackup] = useState(null);
  const [selectedBackups, setSelectedBackups] = useState([]);
  const [searchQuery, setSearchQuery] = useState("");
  const [minDate, setMinDate] = useState(null);
  const [maxDate, setMaxDate] = useState(null);

  useEffect(() => {
    setLoadingRemotes(true);
    fetch(`${API_BASE_URL}/api/v1/remotes`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    })
      .then((response) => response.json())
      .then((data) => {
        setRemotes(data.remotes || []);
        if (data.remotes && data.remotes.length > 0) {
          setSelectedRemote(data.remotes[0]);
        }
        setLoadingRemotes(false);
      })
      .catch((error) => {
        console.error("Error fetching remotes:", error);
        setLoadingRemotes(false);
      });
  }, [token]);

  const fetchBackups = useCallback(
    (remote, pageNum, search, minDt, maxDt) => {
      setLoadingBackups(true);
      let url = `${API_BASE_URL}/api/v1/backups?remote=${remote}&page=${pageNum}&page_size=${pageSize}&sort_by=ModTime&sort_order=desc`;
      if (search) {
        url += `&search=${search}`;
      }
      if (minDt) {
        url += `&min_date=${minDt.toISOString()}`;
      }
      if (maxDt) {
        url += `&max_date=${maxDt.toISOString()}`;
      }

      fetch(url, {
        headers: {
          Authorization: `Bearer ${token}`,
        },
      })
        .then((response) => response.json())
        .then((data) => {
          setBackups(data.items || []);
          setTotalPages(Math.ceil(data.total / data.page_size));
          setLoadingBackups(false);
          setSelectedBackups([]); // Clear selection on new data fetch
        })
        .catch((error) => {
          console.error("Error fetching backups:", error);
          setBackups([]);
          setLoadingBackups(false);
          setSelectedBackups([]);
        });
    },
    [token, pageSize, setLoadingBackups, setBackups, setTotalPages, setSelectedBackups],
  );

  useEffect(() => {
    if (selectedRemote) {
      fetchBackups(selectedRemote, page, searchQuery, minDate, maxDate);
    } else {
      setBackups([]);
    }
  }, [selectedRemote, token, page, searchQuery, minDate, maxDate, fetchBackups]);

  const handlePageChange = (event, value) => {
    setPage(value);
  };

  const handleSearchChange = (event) => {
    setSearchQuery(event.target.value);
    setPage(1); // Reset to first page on search
  };

  const handleMinDateChange = (date) => {
    setMinDate(date);
    setPage(1); // Reset to first page on date change
  };

  const handleMaxDateChange = (date) => {
    setMaxDate(date);
    setPage(1); // Reset to first page on date change
  };

  const formatModifiedDate = (dateString) => {
    try {
      return `${formatDistanceToNow(parseISO(dateString))} ago`;
    } catch (error) {
      return "Invalid date";
    }
  };

  const formatFullDate = (dateString) => {
    try {
      return format(parseISO(dateString), "dd MMM yyyy hh:mm a");
    } catch (error) {
      return "Invalid date";
    }
  };

  const formatBytes = (bytes) => {
    if (bytes === 0) return "0 Bytes";
    const k = 1024;
    const sizes = ["Bytes", "KB", "MB", "GB", "TB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
  };

  const handleDownload = (filename) => {
    fetch(`${API_BASE_URL}/api/v1/backups/download/${selectedRemote}/${filename}`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    })
      .then((response) => {
        if (!response.ok) {
          if (response.status === 403) {
            return response
              .json()
              .then((errorData) => {
                throw new Error(`Permission denied: ${errorData.detail || "Decryption operations are disabled"}`);
              })
              .catch(() => {
                throw new Error(
                  "Permission denied: Backup decryption operations are disabled. Please contact your administrator to enable this feature.",
                );
              });
          }
          // Try to get error details from response
          return response.text().then((text) => {
            let errorMessage = `HTTP ${response.status}`;
            try {
              const errorData = JSON.parse(text);
              errorMessage += `: ${errorData.detail || errorData.message || response.statusText}`;
            } catch {
              errorMessage += `: ${response.statusText || "Unknown error"}`;
            }
            throw new Error(errorMessage);
          });
        }
        return response.blob();
      })
      .then((blob) => {
        const url = window.URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = filename;
        document.body.appendChild(a);
        a.click();
        a.remove();
        window.URL.revokeObjectURL(url);
      })
      .catch((error) => {
        console.error("Error downloading file:", error);
        alert(`Failed to download file: ${error.message}`);
      });
  };

  const handleDelete = (filename) => {
    if (window.confirm(`Are you sure you want to delete ${filename}?`)) {
      fetch(`${API_BASE_URL}/api/v1/backups/${selectedRemote}/${filename}`, {
        method: "DELETE",
        headers: {
          Authorization: `Bearer ${token}`,
        },
      })
        .then((response) => {
          if (!response.ok) {
            return response.text().then((text) => {
              let errorMessage = `HTTP ${response.status}`;
              try {
                const errorData = JSON.parse(text);
                errorMessage += `: ${errorData.detail || errorData.message || response.statusText}`;
              } catch {
                errorMessage += `: ${response.statusText || "Unknown error"}`;
              }
              throw new Error(errorMessage);
            });
          }
          return response.json();
        })
        .then((data) => {
          alert(data.message);
          fetchBackups(selectedRemote, page, searchQuery, minDate, maxDate); // Refresh the list
        })
        .catch((error) => {
          console.error("Error deleting file:", error);
          alert(`Failed to delete file: ${error.message}`);
        });
    }
  };

  const handleRefreshCache = () => {
    if (!selectedRemote) {
      alert("Please select a remote first.");
      return;
    }
    fetch(`${API_BASE_URL}/api/v1/backups/refresh-cache?remote=${selectedRemote}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
    })
      .then((response) => {
        if (!response.ok) {
          return response.text().then((text) => {
            let errorMessage = `HTTP ${response.status}`;
            try {
              const errorData = JSON.parse(text);
              errorMessage += `: ${errorData.detail || errorData.message || response.statusText}`;
            } catch {
              errorMessage += `: ${response.statusText || "Unknown error"}`;
            }
            throw new Error(errorMessage);
          });
        }
        return response.json();
      })
      .then((data) => {
        alert(data.message);
        fetchBackups(selectedRemote, page, searchQuery, minDate, maxDate); // Refresh the list after cache refresh
      })
      .catch((error) => {
        console.error("Error refreshing cache:", error);
        alert(`Failed to refresh cache: ${error.message}`);
      });
  };

  const handleTriggerBackup = () => {
    fetch(`${API_BASE_URL}/api/v1/backups/trigger-backup`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
    })
      .then((response) => {
        if (!response.ok) {
          return response.text().then((text) => {
            let errorMessage = `HTTP ${response.status}`;
            try {
              const errorData = JSON.parse(text);
              errorMessage += `: ${errorData.detail || errorData.message || response.statusText}`;
            } catch {
              errorMessage += `: ${response.statusText || "Unknown error"}`;
            }
            throw new Error(errorMessage);
          });
        }
        return response.json();
      })
      .then((data) => {
        alert(data.message);
        fetchBackups(selectedRemote, page, searchQuery, minDate, maxDate); // Refresh the list after backup
      })
      .catch((error) => {
        console.error("Error triggering backup:", error);
        alert(`Failed to trigger backup: ${error.message}`);
      });
  };

  const handleOpenModal = (filename) => {
    fetch(`${API_BASE_URL}/api/v1/backups/${selectedRemote}/${filename}`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    })
      .then((response) => {
        if (!response.ok) {
          return response.text().then((text) => {
            let errorMessage = `HTTP ${response.status}`;
            try {
              const errorData = JSON.parse(text);
              errorMessage += `: ${errorData.detail || errorData.message || response.statusText}`;
            } catch {
              errorMessage += `: ${response.statusText || "Unknown error"}`;
            }
            throw new Error(errorMessage);
          });
        }
        return response.json();
      })
      .then((data) => {
        setSelectedBackup(data);
        setOpenModal(true);
      })
      .catch((error) => {
        console.error("Error fetching backup details:", error);
        alert(`Failed to fetch backup details: ${error.message}`);
      });
  };

  const handleCloseModal = () => {
    setOpenModal(false);
    setSelectedBackup(null);
  };

  const handleRestore = (filename) => {
    if (window.confirm(`Are you sure you want to restore ${filename}? This will download the decrypted backup file.`)) {
      fetch(`${API_BASE_URL}/api/v1/backups/restore/${selectedRemote}/${filename}`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
        },
      })
        .then((response) => {
          if (!response.ok) {
            if (response.status === 403) {
              return response
                .json()
                .then((errorData) => {
                  throw new Error(`Permission denied: ${errorData.detail || "Decryption operations are disabled"}`);
                })
                .catch(() => {
                  throw new Error(
                    "Permission denied: Backup decryption operations are disabled. Please contact your administrator to enable this feature.",
                  );
                });
            }
            return response.text().then((text) => {
              let errorMessage = `HTTP ${response.status}`;
              try {
                const errorData = JSON.parse(text);
                errorMessage += `: ${errorData.detail || errorData.message || response.statusText}`;
              } catch {
                errorMessage += `: ${response.statusText || "Unknown error"}`;
              }
              throw new Error(errorMessage);
            });
          }
          return response.blob().then((blob) => ({ blob, response }));
        })
        .then(({ blob, response }) => {
          const contentDisposition = response.headers.get("content-disposition");
          let downloadFilename = filename.replace(".enc", ".json");
          if (contentDisposition) {
            const filenameMatch = contentDisposition.match(/filename="?(.+)"?/i);
            if (filenameMatch.length > 1) {
              downloadFilename = filenameMatch[1];
            }
          }
          const url = window.URL.createObjectURL(blob);
          const a = document.createElement("a");
          a.href = url;
          a.download = downloadFilename;
          document.body.appendChild(a);
          a.click();
          a.remove();
          window.URL.revokeObjectURL(url);
          alert("Restore successful! The decrypted backup has been downloaded.");
          handleCloseModal();
        })
        .catch((error) => {
          console.error("Error restoring file:", error);
          alert(`Failed to restore file: ${error.message}`);
        });
    }
  };

  const handleSelectAllClick = (event) => {
    if (event.target.checked) {
      const newSelecteds = backups.map((n) => n.name);
      setSelectedBackups(newSelecteds);
      return;
    }
    setSelectedBackups([]);
  };

  const handleClick = (event, name) => {
    const selectedIndex = selectedBackups.indexOf(name);
    let newSelected = [];

    if (selectedIndex === -1) {
      newSelected = newSelected.concat(selectedBackups, name);
    } else if (selectedIndex === 0) {
      newSelected = newSelected.concat(selectedBackups.slice(1));
    } else if (selectedIndex === selectedBackups.length - 1) {
      newSelected = newSelected.concat(selectedBackups.slice(0, -1));
    } else if (selectedIndex > 0) {
      newSelected = newSelected.concat(selectedBackups.slice(0, selectedIndex), selectedBackups.slice(selectedIndex + 1));
    }
    setSelectedBackups(newSelected);
  };

  const isSelected = (name) => selectedBackups.indexOf(name) !== -1;

  const handleBulkDelete = () => {
    if (selectedBackups.length === 0) {
      alert("Please select at least one backup to delete.");
      return;
    }

    if (window.confirm(`Are you sure you want to delete ${selectedBackups.length} selected backups?`)) {
      fetch(`${API_BASE_URL}/api/v1/backups/${selectedRemote}/bulk-delete`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ files: selectedBackups }),
      })
        .then((response) => {
          if (!response.ok) {
            return response.text().then((text) => {
              let errorMessage = `HTTP ${response.status}`;
              try {
                const errorData = JSON.parse(text);
                errorMessage += `: ${errorData.detail || errorData.message || response.statusText}`;
              } catch {
                errorMessage += `: ${response.statusText || "Unknown error"}`;
              }
              throw new Error(errorMessage);
            });
          }
          return response.json();
        })
        .then((data) => {
          const successfulDeletions = data.results.filter((result) => result.status === "ok").length;
          const failedDeletions = data.results.filter((result) => result.status !== "ok").length;
          alert(`Bulk delete completed.\nSuccessful: ${successfulDeletions}\nFailed: ${failedDeletions}`);
          fetchBackups(selectedRemote, page, searchQuery, minDate, maxDate); // Refresh the list
        })
        .catch((error) => {
          console.error("Error during bulk delete:", error);
          alert(`Failed to perform bulk delete: ${error.message}`);
        });
    }
  };

  if (loadingRemotes) {
    return <CircularProgress />;
  }

  return (
    <Paper elevation={3} sx={{ p: 3 }}>
      <Typography variant="h4" gutterBottom>
        Bitwarden Backups
      </Typography>

      <Grid container spacing={2} alignItems="center" sx={{ mb: 3 }}>
        <Grid item xs={12} sm={4}>
          <FormControl fullWidth>
            <InputLabel id="remote-select-label">Remote</InputLabel>
            <Select
              labelId="remote-select-label"
              id="remote-select"
              value={selectedRemote}
              label="Remote"
              onChange={(e) => setSelectedRemote(e.target.value)}
              disabled={remotes.length === 0}
            >
              {remotes.map((remote) => (
                <MenuItem key={remote} value={remote}>
                  {remote}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
        </Grid>
        <Grid item xs={12} sm={4}>
          <TextField label="Search Filename" variant="outlined" fullWidth value={searchQuery} onChange={handleSearchChange} />
        </Grid>
        <Grid item xs={12} sm={4}>
          <LocalizationProvider dateAdapter={AdapterDateFns}>
            <DatePicker
              label="Min Date"
              value={minDate}
              onChange={handleMinDateChange}
              renderInput={(params) => <TextField {...params} fullWidth />}
            />
          </LocalizationProvider>
        </Grid>
        <Grid item xs={12} sm={4}>
          <LocalizationProvider dateAdapter={AdapterDateFns}>
            <DatePicker
              label="Max Date"
              value={maxDate}
              onChange={handleMaxDateChange}
              renderInput={(params) => <TextField {...params} fullWidth />}
            />
          </LocalizationProvider>
        </Grid>
        <Grid item xs={12} sm={8} sx={{ display: "flex", gap: 1, justifyContent: "flex-end" }}>
          <Button variant="contained" startIcon={<RefreshIcon />} onClick={handleRefreshCache} disabled={!selectedRemote || loadingBackups}>
            Refresh Cache
          </Button>
          <Button variant="contained" color="primary" startIcon={<PlayArrowIcon />} onClick={handleTriggerBackup} disabled={loadingBackups}>
            Trigger Backup
          </Button>
          <Button
            variant="contained"
            color="error"
            startIcon={<DeleteIcon />}
            onClick={handleBulkDelete}
            disabled={selectedBackups.length === 0 || !selectedRemote || loadingBackups}
          >
            Delete Selected ({selectedBackups.length})
          </Button>
        </Grid>
      </Grid>

      {loadingBackups ? (
        <CircularProgress />
      ) : (
        <>
          <TableContainer component={Paper} sx={{ mb: 2 }}>
            <Table sx={{ minWidth: 650 }} aria-label="backups table">
              <TableHead>
                <TableRow>
                  <TableCell padding="checkbox">
                    <Checkbox
                      indeterminate={selectedBackups.length > 0 && selectedBackups.length < backups.length}
                      checked={backups.length > 0 && selectedBackups.length === backups.length}
                      onChange={handleSelectAllClick}
                    />
                  </TableCell>
                  <TableCell>Filename</TableCell>
                  <TableCell align="right">Size</TableCell>
                  <TableCell align="right">Modified Date</TableCell>
                  <TableCell align="right">Download</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {backups.length > 0 ? (
                  backups.map((backup) => {
                    const isItemSelected = isSelected(backup.name);
                    return (
                      <TableRow
                        hover
                        role="checkbox"
                        aria-checked={isItemSelected}
                        tabIndex={-1}
                        key={backup.name}
                        selected={isItemSelected}
                        sx={{ "&:last-child td, &:last-child th": { border: 0 } }}
                      >
                        <TableCell padding="checkbox">
                          <Checkbox checked={isItemSelected} onClick={(event) => handleClick(event, backup.name)} />
                        </TableCell>
                        <TableCell component="th" scope="row">
                          <MuiLink component="button" variant="body2" onClick={() => handleOpenModal(backup.name)}>
                            {backup.name}
                          </MuiLink>
                        </TableCell>
                        <TableCell align="right">{formatBytes(backup.size)}</TableCell>
                        <TableCell align="right">
                          <Tooltip title={formatFullDate(backup.mod_time)}>
                            <span>{formatModifiedDate(backup.mod_time)}</span>
                          </Tooltip>
                        </TableCell>
                        <TableCell align="right">
                          <Tooltip title="Download">
                            <IconButton onClick={() => handleDownload(backup.name)}>
                              <FileDownloadIcon />
                            </IconButton>
                          </Tooltip>
                        </TableCell>
                      </TableRow>
                    );
                  })
                ) : (
                  <TableRow>
                    <TableCell colSpan={5} align="center">
                      No backups found for this remote or matching your filters.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
          <Pagination count={totalPages} page={page} onChange={handlePageChange} sx={{ mt: 2, display: "flex", justifyContent: "center" }} />
        </>
      )}
      <BackupDetailsModal
        open={openModal}
        handleClose={handleCloseModal}
        backup={selectedBackup}
        formatBytes={formatBytes}
        handleDelete={handleDelete}
        handleRestore={handleRestore}
      />
    </Paper>
  );
}

export default Backups;
