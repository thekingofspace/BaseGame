export type RoFluxFile = {
	path: string,
	name: string,
	extension: string,
	source: string,
	text: string,
	className: string,
}

export type RoFluxDeclaration = { [string]: any }

export type RoFluxResult = string | RoFluxDeclaration | { RoFluxDeclaration } | nil

export type RoFluxListener = (file: RoFluxFile) -> RoFluxResult

declare roflux: {
	on: (event: string, callback: RoFluxListener) -> (),
	onRead: (callback: RoFluxListener) -> (),
	onTransfer: (callback: RoFluxListener) -> (),
	onAdded: (callback: RoFluxListener) -> (),
	onRemoved: (callback: RoFluxListener) -> (),
	onChanged: (callback: RoFluxListener) -> (),
	onCompile: (callback: RoFluxListener) -> (),
	onSync: (callback: RoFluxListener) -> (),
	transpile: (extension: string, callback: RoFluxListener) -> (),
	defer: (callback: () -> ()) -> (),
	log: (...any) -> (),
	warn: (...any) -> (),
}
