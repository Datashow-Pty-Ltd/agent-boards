import React from "react";
import ReactDOM from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { Notifications } from "@mantine/notifications";
import "@mantine/core/styles.css";
import "@mantine/notifications/styles.css";
import "skeleton-mammoth/dist/skeleton-mammoth.min.css";
import "./datashow.css";
import "./styles.css";
import { datashowCssVariablesResolver, datashowTheme } from "./theme";
import { App } from "./App";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <MantineProvider
      theme={datashowTheme}
      defaultColorScheme="light"
      forceColorScheme="light"
      cssVariablesResolver={datashowCssVariablesResolver}
    >
      <Notifications position="bottom-right" autoClose={5000} />
      <App />
    </MantineProvider>
  </React.StrictMode>,
);
