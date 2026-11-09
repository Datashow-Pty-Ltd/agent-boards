// Datashow Mantine theme for Ringmaster.
// Source: design_handoff_ringmaster_restyle/design_system/mantine/theme.js
//
// Usage (root.tsx):
//   <MantineProvider theme={datashowTheme} cssVariablesResolver={datashowCssVariablesResolver}
//                    defaultColorScheme="light" forceColorScheme="light">
//
// The system is light-only: there is no dark ramp, so force the light scheme.
// Targets Mantine 9 (requires React 19.2+). Two v9 specifics matter here:
//   1. fontWeights is theme-controlled and the default "medium" moved from
//      500 to 600. This system's working heading weight is 500, so fontWeights
//      is set explicitly below — without it every heading gains weight.
//   2. Light-variant CSS variables are now solid rather than transparent. We
//      never use variant="light", so v8CssVariablesResolver is deliberately
//      NOT applied.

import {
  createTheme,
  type CSSVariablesResolver,
  type MantineColorsTuple,
  type MantineTheme,
} from "@mantine/core";

// The ink ramp expressed as a Mantine 10-step colour. Mantine wants 10 values
// light -> dark; we only ever use 3 (label), 6 (body), 9 (strong).
const ink: MantineColorsTuple = [
  "#f4f3f0",
  "#e8e4db",
  "#d9d4ca",
  "#bfbab0",
  "#a29c92",
  "#837e74",
  "#635f57",
  "#45413a",
  "#2c2925",
  "#1a1815",
];

// Accent — teal. Step 6 is the base; 7 is the pressed state.
const accent: MantineColorsTuple = [
  "#eef4f4",
  "#d7e6e6",
  "#b0cfd0",
  "#86b6b8",
  "#5c9da0",
  "#3a8589",
  "#226f74",
  "#1b5b5f",
  "#14464a",
  "#0d3134",
];

// Alert — deep red for blocked states and over-limit figures.
const alert: MantineColorsTuple = [
  "#f7eef1",
  "#ecd7de",
  "#dbb2bf",
  "#c98da1",
  "#b96b86",
  "#a8496c",
  "#8b2440",
  "#741e36",
  "#5c182b",
  "#451221",
];

export const DS = {
  ink: "#1a1815",
  ink2: "#45413a",
  ink3: "#837e74",
  ink4: "#bfbab0",
  hair: "#d9d4ca",
  hair2: "#e8e4db",
  hair3: "#f2efe9",
  inset: "#f4f3f0",
  paper: "#ffffff",
  accent: "#226f74",
  alert: "#8b2440",
  control: "#a8542f",
  fall: "#2e7e83",
  rise: "#b04f6e",
  sans: "'IBM Plex Sans', system-ui, -apple-system, sans-serif",
  serif: "'IBM Plex Serif', Georgia, serif",
  mono: "'IBM Plex Mono', ui-monospace, Menlo, monospace",
} as const;

/**
 * One geometry for every control.
 *
 * Buttons, segmented controls and inputs sit next to each other in a header
 * bar, so their height is a shared fact rather than each component's own
 * decision. Anything that renders as a control reads these, including the
 * Mantine defaults below, which is what stops the sizes drifting apart again.
 */
export const CONTROL = {
  /** Outer height of any control, borders included. */
  height: 30,
  paddingX: 14,
  fontSize: 10,
  letterSpacing: "0.1em",
  radius: 1,
} as const;

export const datashowTheme = createTheme({
  primaryColor: "accent",
  primaryShade: 6,
  colors: {
    ink,
    accent,
    alert,
    // Every Mantine palette name is remapped onto the house ramps, so any code
    // that still says gray/blue/violet/grape/… lands on ink, teal, or deep red.
    // Nothing in this system may render in Mantine's default rainbow.
    gray: ink,
    dark: ink,
    blue: accent,
    green: accent,
    teal: accent,
    cyan: accent,
    indigo: accent,
    violet: accent,
    grape: accent,
    lime: accent,
    red: alert,
    orange: alert,
    yellow: alert,
    pink: alert,
  },

  white: "#ffffff",
  black: "#1a1815",

  fontFamily: DS.sans,
  fontFamilyMonospace: DS.mono,
  headings: {
    fontFamily: DS.sans,
    fontWeight: "500",
    sizes: {
      h1: { fontSize: "96px", lineHeight: "0.92" },
      h2: { fontSize: "36px", lineHeight: "1.05" },
      h3: { fontSize: "28px", lineHeight: "1.1" },
      h4: { fontSize: "19px", lineHeight: "1.2" },
    },
  },

  // v9: components read these instead of hardcoded weights. 500 is the working
  // heading weight in this system and 600 is held in reserve.
  fontWeights: { regular: "400", medium: "500", bold: "600" },

  fontSizes: { xs: "9.5px", sm: "11px", md: "14.5px", lg: "16px", xl: "19px" },
  lineHeights: { xs: "1.4", sm: "1.5", md: "1.5", lg: "1.5", xl: "1.2" },

  // Zero radius everywhere. A pill's 1px is applied per-component below.
  defaultRadius: 0,
  radius: { xs: "0px", sm: "0px", md: "0px", lg: "0px", xl: "1px" },

  spacing: { xs: "8px", sm: "12px", md: "16px", lg: "22px", xl: "32px" },

  // Nothing floats. The board story-detail overlay carries its own mirrored
  // shadow inline — the sole exception in the system.
  shadows: { xs: "none", sm: "none", md: "none", lg: "none", xl: "none" },

  other: {
    hair: DS.hair,
    hair2: DS.hair2,
    hair3: DS.hair3,
    inset: DS.inset,
    serif: DS.serif,
    ruleWidth: "1px",
    kickerTracking: "0.14em",
    labelTracking: "0.08em",
  },

  components: {
    // Buttons are bordered labels in Mono, uppercase, tracked.
    Button: {
      defaultProps: { radius: 1, variant: "default" },
      styles: (theme: MantineTheme) => ({
        root: {
          fontFamily: theme.fontFamilyMonospace,
          fontSize: `${CONTROL.fontSize}px`,
          fontWeight: 400,
          letterSpacing: CONTROL.letterSpacing,
          textTransform: "uppercase" as const,
          borderColor: theme.other.hair as string,
          height: CONTROL.height,
          padding: `0 ${CONTROL.paddingX}px`,
        },
        label: { justifyContent: "flex-start" },
      }),
    },
    Badge: {
      defaultProps: { radius: 1, variant: "outline", color: "ink.5" },
      styles: (theme: MantineTheme) => ({
        root: {
          fontFamily: theme.fontFamilyMonospace,
          fontSize: "10px",
          fontWeight: 400,
          letterSpacing: "0.1em",
          borderColor: theme.other.hair as string,
          textTransform: "uppercase" as const,
        },
      }),
    },
    Paper: {
      defaultProps: {
        radius: 0,
        shadow: undefined,
        withBorder: true,
        bg: "white",
      },
    },
    Card: {
      defaultProps: {
        radius: 0,
        shadow: undefined,
        withBorder: true,
        bg: "white",
        padding: 0,
      },
    },
    Divider: { defaultProps: { color: "ink.1" } },
    Input: {
      defaultProps: { radius: 1 },
      styles: (theme: MantineTheme) => ({
        input: {
          fontFamily: theme.fontFamilyMonospace,
          fontSize: "12px",
          letterSpacing: "0.04em",
          borderColor: theme.other.hair as string,
        },
      }),
    },
    InputWrapper: {
      styles: (theme: MantineTheme) => ({
        label: {
          fontFamily: theme.fontFamilyMonospace,
          fontSize: "9.5px",
          fontWeight: 400,
          letterSpacing: "0.12em",
          textTransform: "uppercase" as const,
          color: theme.colors.ink[5],
          marginBottom: "6px",
        },
      }),
    },
    // Reads the same geometry as the house controls, so a Mantine control and
    // a house control standing side by side are the same height.
    SegmentedControl: {
      defaultProps: { radius: 0, color: "ink.9", transitionDuration: 0 },
      styles: (theme: MantineTheme) => ({
        root: {
          background: "transparent",
          border: "1px solid " + (theme.other.hair as string),
          padding: 0,
          height: CONTROL.height,
          boxSizing: "border-box" as const,
        },
        label: {
          fontFamily: theme.fontFamilyMonospace,
          fontSize: `${CONTROL.fontSize}px`,
          letterSpacing: CONTROL.letterSpacing,
          textTransform: "uppercase" as const,
          padding: `0 ${CONTROL.paddingX}px`,
          display: "flex",
          alignItems: "center",
        },
        indicator: { borderRadius: 0, boxShadow: "none" },
      }),
    },
    Table: {
      defaultProps: {
        horizontalSpacing: 0,
        verticalSpacing: 10,
        withRowBorders: true,
      },
      styles: (theme: MantineTheme) => ({
        th: {
          fontFamily: theme.fontFamilyMonospace,
          fontSize: "9.5px",
          fontWeight: 400,
          letterSpacing: "0.12em",
          textTransform: "uppercase" as const,
          color: theme.colors.ink[5],
          borderBottom: "1px solid " + theme.black,
        },
        td: {
          fontSize: "13.5px",
          borderBottom: "1px solid " + (theme.other.hair3 as string),
        },
      }),
    },
    Tooltip: {
      defaultProps: { radius: 0, color: "ink.9" },
      styles: (theme: MantineTheme) => ({
        tooltip: {
          fontFamily: theme.fontFamilyMonospace,
          fontSize: "10px",
          letterSpacing: "0.08em",
          textTransform: "uppercase" as const,
        },
      }),
    },
    Modal: { defaultProps: { radius: 0, shadow: undefined, centered: true } },
    Anchor: { defaultProps: { underline: "never", c: "ink.9" } },
    Checkbox: { defaultProps: { radius: 0, color: "ink.9", size: "xs" } },
    Switch: { defaultProps: { color: "ink.9" } },
    Loader: { defaultProps: { color: "ink.5", type: "dots" } },
    Alert: { defaultProps: { radius: 0 } },
    Select: {
      styles: (theme: MantineTheme) => ({
        input: {
          fontFamily: theme.fontFamilyMonospace,
          fontSize: "12px",
          letterSpacing: "0.04em",
          borderColor: theme.other.hair as string,
        },
        option: { fontSize: "12.5px", borderRadius: 0 },
        dropdown: {
          borderRadius: 0,
          borderColor: theme.other.hair as string,
        },
      }),
    },
    Menu: {
      defaultProps: { radius: 0, shadow: undefined },
      styles: (theme: MantineTheme) => ({
        dropdown: {
          borderRadius: 0,
          borderColor: theme.other.hair as string,
        },
        item: { borderRadius: 0, fontSize: "12.5px" },
        label: {
          fontFamily: theme.fontFamilyMonospace,
          fontSize: "9.5px",
          letterSpacing: "0.12em",
          textTransform: "uppercase" as const,
          color: theme.colors.ink[5],
        },
      }),
    },
  },
});

// Maps the design system's own tokens onto Mantine variables so both
// vocabularies resolve to the same values in one app. Heading variables are
// emitted with concrete values because React Router's critical CSS extraction
// splits Mantine's calc() defaults across <style> blocks, where they resolve
// to NaN.
export const datashowCssVariablesResolver: CSSVariablesResolver = (theme) => ({
  variables: {
    "--mantine-color-body": "#ffffff",
    "--mantine-color-text": theme.black,
    "--mantine-color-dimmed": theme.colors.ink[5],
    "--mantine-color-default-border": theme.other.hair as string,
    "--mantine-hair": theme.other.hair as string,
    "--mantine-hair-2": theme.other.hair2 as string,
    "--mantine-hair-3": theme.other.hair3 as string,
    "--mantine-font-family-serif": theme.other.serif as string,
    "--mantine-h1-font-size": "96px",
    "--mantine-h1-font-weight": "500",
    "--mantine-h1-line-height": "0.92",
    "--mantine-h2-font-size": "36px",
    "--mantine-h2-font-weight": "500",
    "--mantine-h2-line-height": "1.05",
    "--mantine-h3-font-size": "28px",
    "--mantine-h3-font-weight": "500",
    "--mantine-h3-line-height": "1.1",
    "--mantine-h4-font-size": "19px",
    "--mantine-h4-font-weight": "500",
    "--mantine-h4-line-height": "1.2",
    "--mantine-h5-font-size": "16px",
    "--mantine-h5-font-weight": "500",
    "--mantine-h5-line-height": "1.3",
    "--mantine-h6-font-size": "14.5px",
    "--mantine-h6-font-weight": "500",
    "--mantine-h6-line-height": "1.4",
  },
  light: {},
  dark: {},
});

export default datashowTheme;
