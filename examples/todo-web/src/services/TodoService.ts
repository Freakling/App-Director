import { TodoStore, Todo } from '../store/TodoStore';

export { Todo };

export class TodoService {
  constructor(private store: TodoStore) {}

  getAll(): Todo[] { return this.store.getAll(); }
  add(title: string): void { this.store.add(title.trim()); }
  toggle(id: number): void { this.store.toggle(id); }
  remove(id: number): void { this.store.remove(id); }
}
