import React from "react";
import { Navigate, useLocation } from "react-router-dom";

function PrivateRoute({ children, token }) {
  let location = useLocation();

  if (!token) {
    return <Navigate to="/login" state={{ from: location }} replace />;
  }

  return children;
}

export default PrivateRoute;
