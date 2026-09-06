import type * as React from 'react';

export interface LeanConstructor<Tag extends string = string, Fields extends readonly unknown[] = readonly unknown[]> {
  readonly tag: Tag;
  readonly fields: Fields;
}
export declare function ctor<Tag extends string, Fields extends readonly unknown[]>(tag: Tag, fields: Fields): LeanConstructor<Tag, Fields>;
export declare const unit: LeanConstructor<'Unit.unit', readonly []>;
export declare function mountElement(descriptor: unknown, props?: unknown): React.ReactNode;
export declare function asReactComponent<Props extends object>(descriptor: unknown, encodeProps: (props: Props) => unknown): React.ComponentType<Props>;
