import { TodoService } from '../services/TodoService';

export function renderTodoList(service: TodoService): string {
  const items = service.getAll();
  if (items.length === 0) return '<p class="empty">No tasks yet.</p>';
  return '<ul>' + items.map(t =>
    `<li class="${t.done ? 'done' : ''}">` +
    `<span>${t.title}</span>` +
    `<button data-id="${t.id}" class="toggle">✓</button>` +
    `<button data-id="${t.id}" class="remove">✕</button>` +
    `</li>`
  ).join('') + '</ul>';
}

export function renderAddForm(): string {
  return '<input id="new-todo" type="text" placeholder="Add a task…"> <button id="add">Add</button>';
}
