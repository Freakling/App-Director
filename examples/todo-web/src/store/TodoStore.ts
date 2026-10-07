export interface Todo {
  id: number;
  title: string;
  done: boolean;
}

export class TodoStore {
  private items: Todo[] = [];
  private seq = 1;

  getAll(): Todo[] { return [...this.items]; }

  add(title: string): Todo {
    const t: Todo = { id: this.seq++, title, done: false };
    this.items.push(t);
    return t;
  }

  toggle(id: number): void {
    const t = this.items.find(x => x.id === id);
    if (t) t.done = !t.done;
  }

  remove(id: number): void {
    this.items = this.items.filter(x => x.id !== id);
  }
}
