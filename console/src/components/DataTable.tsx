import { flexRender, type Row, type Table } from '@tanstack/react-table';
import { ArrowDown, ArrowUp } from 'lucide-react';
import styles from './DataTable.module.css';

/**
 * The markup for a TanStack table: a scrolling box, a sticky header with sort
 * arrows, and an empty row. The page owns the table instance — its columns,
 * filters and sort — and this owns only how it looks, so the log and the
 * process list read as the same kind of thing.
 */
export default function DataTable<T>({
  table,
  fill,
  rowClassName,
  cellClassName,
  onRowClick,
  onRowHover,
  minWidth,
}: {
  table: Table<T>;
  /** The column that takes whatever width the sized ones leave. */
  fill?: string;
  rowClassName?: (row: Row<T>) => string | undefined;
  cellClassName?: (columnId: string) => string | undefined;
  /** A row that opens something: the whole row is the target. */
  onRowClick?: (row: Row<T>) => void;
  /** The row under the pointer, and null when it leaves the table: for a
      page that highlights the same thing elsewhere. */
  onRowHover?: (row: Row<T> | null) => void;
  /** Below this the table scrolls sideways rather than squeezing its fill
      column to nothing. */
  minWidth?: number;
}) {
  const rows = table.getRowModel().rows;
  const columns = table.getVisibleLeafColumns();

  return (
    <div className={styles.scroller}>
      <table className={styles.table} style={minWidth ? { minWidth } : undefined}>
        <colgroup>
          {columns.map((col) => (
            <col key={col.id} style={col.id === fill ? undefined : { width: col.getSize() }} />
          ))}
        </colgroup>
        <thead>
          {table.getHeaderGroups().map((group) => (
            <tr key={group.id}>
              {group.headers.map((header) => {
                const sorted = header.column.getIsSorted();
                const numeric = header.column.columnDef.meta?.numeric;
                return (
                  <th
                    key={header.id}
                    className={`${header.column.getCanSort() ? styles.sortable : ''} ${numeric ? styles.numeric : ''}`}
                    onClick={header.column.getToggleSortingHandler()}
                  >
                    {flexRender(header.column.columnDef.header, header.getContext())}
                    {sorted === 'asc' && <ArrowUp size={12} strokeWidth={2} />}
                    {sorted === 'desc' && <ArrowDown size={12} strokeWidth={2} />}
                  </th>
                );
              })}
            </tr>
          ))}
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.id} className={rowClassName?.(row)}
                onClick={onRowClick ? () => onRowClick(row) : undefined}
                onMouseEnter={onRowHover ? () => onRowHover(row) : undefined}
                onMouseLeave={onRowHover ? () => onRowHover(null) : undefined}>
              {row.getVisibleCells().map((cell) => (
                <td
                  key={cell.id}
                  className={`${cellClassName?.(cell.column.id) ?? ''} ${
                    cell.column.columnDef.meta?.numeric ? styles.numeric : ''
                  }`}
                >
                  {flexRender(cell.column.columnDef.cell, cell.getContext())}
                </td>
              ))}
            </tr>
          ))}
          {!rows.length && (
            <tr>
              <td colSpan={columns.length} className={styles.empty}>
                Nothing matches.
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
