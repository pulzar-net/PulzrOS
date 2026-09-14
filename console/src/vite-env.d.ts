/// <reference types="vite/client" />

/**
 * CSS modules.
 *
 * Vite handles these at build time; TypeScript needs telling they exist. The
 * value type is loose on purpose — generating exact class-name types would
 * mean a codegen step in the image pipeline for a benefit that a typo in a
 * class name (which renders unstyled and is immediately visible) does not
 * justify.
 */
declare module '*.module.css' {
  const classes: Record<string, string>;
  export default classes;
}
