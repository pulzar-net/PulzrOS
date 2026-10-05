import '@tanstack/react-table';

declare module '@tanstack/react-table' {
  // Read by DataTable: right-aligned, tabular figures.
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  interface ColumnMeta<TData extends RowData, TValue> {
    numeric?: boolean;
  }
}
